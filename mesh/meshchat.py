#!/usr/bin/env python3
"""HAS_PrepperDisk mesh sohbet köprüsü / mesh chat bridge.

USB ile bağlı bir Meshtastic cihazını (Meschy) Pi'nin Wi-Fi ağına açar.
Hotspot'a bağlanan herkes tarayıcıdan mesh ağına mesaj atıp okuyabilir.
Mesajlar SQLite'a kaydedilir, böylece sonradan bağlanan da geçmişi görür.

Bridges a USB-attached Meshtastic node (Meschy) to the Pi's Wi-Fi network.
Anyone on the hotspot can read and send mesh messages from a browser.
Messages are stored in SQLite so people who join later can see the history.

Ayarlar ortam değişkenleriyle yapılır (/etc/default/has-meshchat):
Settings come from environment variables (/etc/default/has-meshchat):
  MESHCHAT_DEVICE     seri port, boşsa otomatik / serial port, empty = auto
  MESHCHAT_DB         SQLite dosyası / database file
  MESHCHAT_HOST       dinlenen adres / listen address (127.0.0.1, behind nginx)
  MESHCHAT_PORT       dinlenen port / listen port (8095)
  MESHCHAT_CHANNEL    gönderilen kanal / channel index to send on (0 = primary)
  MESHCHAT_MAX_BYTES  takma ad dahil mesaj sınırı / max message bytes incl. nickname
  MESHCHAT_COOLDOWN   aynı cihazdan iki mesaj arası saniye / seconds between sends per client
"""

import glob
import json
import logging
import os
import re
import sqlite3
import threading
import time
import unicodedata
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

log = logging.getLogger("meshchat")

DEVICE = os.getenv("MESHCHAT_DEVICE", "").strip()
DB_PATH = os.getenv("MESHCHAT_DB", "/library/meshchat/meshchat.db")
HOST = os.getenv("MESHCHAT_HOST", "127.0.0.1")
PORT = int(os.getenv("MESHCHAT_PORT", "8095"))
CHANNEL = int(os.getenv("MESHCHAT_CHANNEL", "0"))
# Meshtastic paket yükü en fazla 233 bayt; biraz pay bırakıyoruz.
# A Meshtastic payload is at most 233 bytes; keep some headroom.
MAX_BYTES = min(int(os.getenv("MESHCHAT_MAX_BYTES", "200")), 228)
COOLDOWN = float(os.getenv("MESHCHAT_COOLDOWN", "5"))
MAX_NICK = 16
RETRY_SECONDS = 10
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


def clean_text(value, limit_chars):
    """Kontrol karakterlerini at, boşlukları sadeleştir / drop control chars, squeeze spaces."""
    value = unicodedata.normalize("NFC", str(value))
    value = "".join(ch for ch in value if unicodedata.category(ch)[0] != "C" or ch == " ")
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit_chars]


# --------------------------------------------------------------------- storage
class Store:
    def __init__(self, path):
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        with self.lock:
            self.db.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS messages (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    packet_id INTEGER,
                    ts        REAL    NOT NULL,
                    direction TEXT    NOT NULL,   -- in / out
                    from_id   TEXT,
                    from_name TEXT,
                    to_id     TEXT,
                    channel   INTEGER,
                    text      TEXT    NOT NULL,
                    snr       REAL,
                    rssi      INTEGER,
                    hops      INTEGER,
                    status    TEXT                -- out: queued/sent/relayed/failed
                );
                CREATE UNIQUE INDEX IF NOT EXISTS uniq_packet
                    ON messages(direction, from_id, packet_id);
                """
            )
            self.db.commit()

    def add(self, **row):
        cols = ", ".join(row)
        marks = ", ".join("?" for _ in row)
        with self.lock:
            cur = self.db.execute(
                f"INSERT OR IGNORE INTO messages ({cols}) VALUES ({marks})", tuple(row.values())
            )
            self.db.commit()
            return cur.lastrowid if cur.rowcount else None

    def set_status(self, row_id, status):
        with self.lock:
            self.db.execute("UPDATE messages SET status=? WHERE id=?", (status, row_id))
            self.db.commit()

    def mark_sent(self, row_id, packet_id):
        # Onay sendData dönmeden gelmiş olabilir; onu ezme.
        # The ACK may already have arrived before sendData returned; don't overwrite it.
        with self.lock:
            self.db.execute(
                "UPDATE messages SET packet_id=?, "
                "status=CASE WHEN status='queued' THEN 'sent' ELSE status END WHERE id=?",
                (packet_id, row_id),
            )
            self.db.commit()

    def since(self, after_id, limit):
        with self.lock:
            if after_id > 0:
                rows = self.db.execute(
                    "SELECT * FROM messages WHERE id>? ORDER BY id LIMIT ?", (after_id, limit)
                ).fetchall()
            else:  # ilk yükleme: son N mesaj / first load: last N messages
                rows = self.db.execute(
                    "SELECT * FROM (SELECT * FROM messages ORDER BY id DESC LIMIT ?) ORDER BY id",
                    (limit,),
                ).fetchall()
        return [dict(r) for r in rows]

    def updated_statuses(self, ids):
        if not ids:
            return {}
        with self.lock:
            rows = self.db.execute(
                f"SELECT id, status FROM messages WHERE id IN ({','.join('?' * len(ids))})", ids
            ).fetchall()
        return {r["id"]: r["status"] for r in rows}


# ----------------------------------------------------------------------- radio
def find_device():
    """Meshtastic cihazını bul / find the Meshtastic serial device."""
    if DEVICE:
        return DEVICE if os.path.exists(DEVICE) else None
    try:
        import meshtastic.util

        ports = meshtastic.util.findPorts(True)
        if ports:
            return ports[0]
    except Exception as exc:  # pragma: no cover - depends on hardware
        log.debug("findPorts failed: %s", exc)
    for pattern in ("/dev/serial/by-id/*", "/dev/ttyACM*", "/dev/ttyUSB*"):
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    return None


class Radio:
    """Meshtastic bağlantısını yönetir, koparsa yeniden bağlanır.
    Keeps the Meshtastic connection alive and reconnects when it drops."""

    def __init__(self, store, interface_factory=None):
        self.store = store
        self.iface = None
        self.device = None
        self.error = "Başlatılıyor / starting"
        self.lock = threading.Lock()
        self.lost = threading.Event()
        self._factory = interface_factory

    # pubsub geri çağrıları / pubsub callbacks -------------------------------
    def on_text(self, packet, interface=None):
        try:
            decoded = packet.get("decoded", {})
            text = decoded.get("text")
            if not text:
                return
            from_id = packet.get("fromId") or f"!{packet.get('from', 0):08x}"
            my_id = self.my_id()
            if from_id == my_id:
                return  # kendi gönderdiğimiz / our own message
            hop_start, hop_limit = packet.get("hopStart"), packet.get("hopLimit")
            self.store.add(
                packet_id=packet.get("id"),
                ts=packet.get("rxTime") or time.time(),
                direction="in",
                from_id=from_id,
                from_name=self.node_name(from_id),
                to_id=packet.get("toId") or "^all",
                channel=packet.get("channel", 0),
                text=clean_text(text, 500),
                snr=packet.get("rxSnr"),
                rssi=packet.get("rxRssi"),
                hops=(hop_start - hop_limit) if hop_start is not None and hop_limit is not None else None,
                status=None,
            )
        except Exception:
            log.exception("could not store incoming packet")

    def on_lost(self, interface=None):
        log.warning("Radyo bağlantısı koptu / radio connection lost")
        self.lost.set()

    # yardımcılar / helpers ---------------------------------------------------
    def connected(self):
        iface = self.iface
        return bool(iface and iface.isConnected.is_set())

    def my_id(self):
        iface = self.iface
        try:
            info = iface.getMyNodeInfo() if iface else None
            return (info or {}).get("user", {}).get("id")
        except Exception:
            return None

    def node_name(self, node_id):
        iface = self.iface
        try:
            user = (iface.nodes or {}).get(node_id, {}).get("user", {}) if iface else {}
            return user.get("longName") or user.get("shortName") or node_id
        except Exception:
            return node_id

    def status(self):
        iface = self.iface
        out = {"connected": self.connected(), "device": self.device, "error": None,
               "me": None, "nodes": [], "maxBytes": MAX_BYTES, "cooldown": COOLDOWN}
        if not out["connected"]:
            out["error"] = self.error
            return out
        try:
            info = iface.getMyNodeInfo() or {}
            user = info.get("user", {})
            out["me"] = {"id": user.get("id"), "longName": user.get("longName"),
                         "shortName": user.get("shortName")}
            now = time.time()
            for node_id, node in list((iface.nodes or {}).items()):
                if node_id == out["me"]["id"]:
                    continue
                u = node.get("user", {})
                metrics = node.get("deviceMetrics", {})
                out["nodes"].append({
                    "id": node_id,
                    "longName": u.get("longName") or node_id,
                    "shortName": u.get("shortName"),
                    "lastHeard": node.get("lastHeard"),
                    "ago": int(now - node["lastHeard"]) if node.get("lastHeard") else None,
                    "snr": node.get("snr"),
                    "hops": node.get("hopsAway"),
                    "battery": metrics.get("batteryLevel"),
                })
            out["nodes"].sort(key=lambda n: -(n["lastHeard"] or 0))
        except Exception as exc:
            out["error"] = str(exc)
        return out

    def send(self, text):
        """Metni mesh'e yayınla / broadcast text to the mesh. Returns stored row id."""
        iface = self.iface
        if not self.connected():
            raise RuntimeError("Radyo bağlı değil / radio not connected")
        my_id = self.my_id()
        row_id = self.store.add(packet_id=None, ts=time.time(), direction="out", from_id=my_id,
                                from_name=None, to_id="^all", channel=CHANNEL, text=text,
                                snr=None, rssi=None, hops=None, status="queued")
        def on_ack(packet):
            # Yayın mesajlarında cihaz, başka bir düğümün mesajı tekrar yayınladığını
            # duyunca "örtük onay" verir. Kimse duymazsa MAX_RETRANSMIT hatası gelir.
            # For broadcasts the node reports an implicit ACK once it hears another
            # node rebroadcast the message; if nobody does, it reports MAX_RETRANSMIT.
            routing = packet.get("decoded", {}).get("routing", {})
            reason = routing.get("errorReason", "NONE")
            if reason == "NONE":
                self.store.set_status(row_id, "relayed")
            elif reason == "MAX_RETRANSMIT":
                self.store.set_status(row_id, "unheard")
            else:
                self.store.set_status(row_id, "failed")

        from meshtastic.protobuf import portnums_pb2

        with self.lock:
            pkt = iface.sendData(
                text.encode("utf-8"),
                portNum=portnums_pb2.PortNum.TEXT_MESSAGE_APP,
                wantAck=True,
                onResponse=on_ack,
                onResponseAckPermitted=True,
                channelIndex=CHANNEL,
            )
        self.store.mark_sent(row_id, getattr(pkt, "id", None))
        return row_id

    # bağlantı döngüsü / connection loop -------------------------------------
    def _open(self, path):
        if self._factory:
            return self._factory(path)
        import meshtastic.serial_interface

        return meshtastic.serial_interface.SerialInterface(devPath=path, timeout=60)

    def run(self):
        from pubsub import pub

        pub.subscribe(self.on_text, "meshtastic.receive.text")
        pub.subscribe(self.on_lost, "meshtastic.connection.lost")
        while True:
            path = find_device()
            if not path:
                self.error = "Meshtastic cihazı bulunamadı, USB'ye takılı mı? / no Meshtastic device found"
                time.sleep(RETRY_SECONDS)
                continue
            try:
                log.info("Bağlanılıyor / connecting: %s", path)
                self.lost.clear()
                iface = self._open(path)
                self.iface, self.device, self.error = iface, path, None
                log.info("Bağlandı / connected: %s (%s)", path, self.my_id())
                while not self.lost.wait(5):
                    if not os.path.exists(path):  # USB çıkarıldı / unplugged
                        break
            except BaseException as exc:  # meshtastic bazen SystemExit atar / may raise SystemExit
                if isinstance(exc, KeyboardInterrupt):
                    raise
                self.error = f"Bağlantı hatası / connection error: {exc}"
                log.warning(self.error)
            finally:
                iface, self.iface = self.iface, None
                if iface:
                    try:
                        iface.close()
                    except Exception:
                        pass
            time.sleep(RETRY_SECONDS)


# ------------------------------------------------------------------------ http
class Handler(BaseHTTPRequestHandler):
    server_version = "HASMeshChat/1.0"
    radio = None
    store = None
    last_send = {}
    last_send_lock = threading.Lock()

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.client_ip(), fmt % args)

    def client_ip(self):
        ip = self.client_address[0]
        # nginx arkasındayız; X-Real-IP'ye sadece yerelden gelirse güven.
        # Trust X-Real-IP only when the request comes from local nginx.
        if ip in ("127.0.0.1", "::1"):
            ip = self.headers.get("X-Real-IP", ip)
        return ip

    def send_json(self, data, code=HTTPStatus.OK):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            with open(os.path.join(STATIC_DIR, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif url.path == "/api/status":
            self.send_json(self.radio.status())
        elif url.path == "/api/messages":
            q = parse_qs(url.query)
            try:
                after = max(0, int(q.get("after", ["0"])[0]))
                limit = min(500, max(1, int(q.get("limit", ["200"])[0])))
                watch = [int(x) for x in q.get("watch", [""])[0].split(",") if x][:50]
            except ValueError:
                return self.send_json({"error": "bad query"}, HTTPStatus.BAD_REQUEST)
            self.send_json({"messages": self.store.since(after, limit),
                            "statuses": self.store.updated_statuses(watch)})
        else:
            self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if urlparse(self.path).path != "/api/send":
            return self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 4096:
            return self.send_json({"error": "Geçersiz istek / bad request"}, HTTPStatus.BAD_REQUEST)
        try:
            data = json.loads(self.rfile.read(length))
            nick = clean_text(data.get("name", ""), MAX_NICK)
            text = clean_text(data.get("text", ""), 1000)
        except (ValueError, AttributeError):
            return self.send_json({"error": "Geçersiz istek / bad request"}, HTTPStatus.BAD_REQUEST)
        if not text:
            return self.send_json({"error": "Mesaj boş / empty message"}, HTTPStatus.BAD_REQUEST)
        full = f"{nick}: {text}" if nick else text
        if len(full.encode("utf-8")) > MAX_BYTES:
            return self.send_json({"error": f"Mesaj çok uzun, en fazla {MAX_BYTES} bayt / too long"},
                                  HTTPStatus.REQUEST_ENTITY_TOO_LARGE)

        ip = self.client_ip()
        with self.last_send_lock:
            wait = COOLDOWN - (time.monotonic() - self.last_send.get(ip, -1e9))
            if wait > 0:
                return self.send_json({"error": f"Biraz bekleyin ({wait:.0f} sn) / please wait",
                                       "retryAfter": wait}, HTTPStatus.TOO_MANY_REQUESTS)
            self.last_send[ip] = time.monotonic()
        try:
            row_id = self.radio.send(full)
        except Exception as exc:
            with self.last_send_lock:
                self.last_send.pop(ip, None)
            return self.send_json({"error": str(exc)}, HTTPStatus.SERVICE_UNAVAILABLE)
        log.info("gönderildi / sent from %s: %r", ip, full)
        self.send_json({"ok": True, "id": row_id})


def main():
    logging.basicConfig(level=os.getenv("MESHCHAT_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    store = Store(DB_PATH)
    radio = Radio(store)
    threading.Thread(target=radio.run, name="radio", daemon=True).start()
    Handler.radio, Handler.store = radio, store
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    log.info("Mesh sohbet hazır / mesh chat ready: http://%s:%d/", HOST, PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
