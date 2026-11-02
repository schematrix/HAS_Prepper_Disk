#!/usr/bin/env python3
"""HAS_PrepperDisk Güvendeyim panosu: http://box.lan/pano/

Ağa bağlı herkes "güvendeyim" ya da "yardım lazım" kaydı bırakabilir ve isimle arayabilir.
Kayıtlar yalnızca bu kutuda durur. Kaydı yazan kişi, aldığı silme koduyla kaydını silebilir;
kutunun sahibi tüm kayıtları scripts/pano.sh ile siler.

"I'm safe" board: anyone on the network can leave an "I'm safe" or "need help" entry and search
by name. Entries stay on this box only. The writer can delete an entry with the code they get;
the box owner wipes everything with scripts/pano.sh.

  GET  /pano/kayitlar?q=ayse      son kayıtlar ya da arama / latest entries or search
  POST /pano/kayitlar             {"ad","durum","yer","mesaj"} -> {"id","kod"}
  POST /pano/sil                  {"id","kod"}
"""
import hashlib
import json
import os
import secrets
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DATA = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/has-pano"), "guvendeyim.json")
PORT = int(os.environ.get("PORT", "8098"))
MAX_ENTRIES = 20000
LIMITS = {"ad": 60, "yer": 80, "mesaj": 280}
DURUMLAR = ("guvende", "yardim")
# Aynı cihazdan 10 dakikada en fazla 10 kayıt / at most 10 entries per device per 10 minutes
RATE_N, RATE_WINDOW = 10, 600

lock = threading.Lock()
recent = {}
fails = {}


def load():
    try:
        with open(DATA, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def save(entries):
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False)
    os.replace(tmp, DATA)


entries = load()

# "İ"/"I" Türkçede ayrı harfler; aramada "ayse" "Ayşe"yi, "ismail" "İsmail"i bulsun.
# Turkish dotted/dotless i and other letters fold to ASCII so "ayse" finds "Ayşe".
FOLD = str.maketrans("çğıöşüâîû", "cgiosuaiu")


def norm(s):
    return " ".join(s.replace("İ", "i").replace("I", "ı").lower().translate(FOLD).split())


def clean(v, limit):
    if not isinstance(v, str):
        return ""
    return " ".join("".join(c for c in v if c.isprintable()).split())[:limit]


def public(e):
    return {k: e[k] for k in ("id", "ad", "durum", "yer", "mesaj", "zaman")}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self):
        # Yalnızca JSON: başka bir site bu isteği ziyaretçinin tarayıcısından CORS ön kontrolü olmadan atamaz.
        # JSON only: another site cannot send this from a visitor's browser without a CORS preflight.
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            return None
        try:
            data = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 2048)))
        except ValueError:
            return None
        return data if isinstance(data, dict) else None

    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/kayitlar":
            return self._send(404, {"error": "bulunamadı / not found"})
        words = norm(parse_qs(url.query).get("q", [""])[0][:100]).split()
        with lock:
            found = [e for e in reversed(entries) if all(w in e["ara"] for w in words)]
        self._send(200, {"toplam": len(entries), "bulunan": len(found), "kayitlar": [public(e) for e in found[:100]]})

    def do_POST(self):
        data = self._json()
        if data is None:
            return self._send(400, {"error": "Geçersiz istek / bad request"})
        if self.path == "/kayitlar":
            return self.add(data)
        if self.path == "/sil":
            return self.delete(data)
        self._send(404, {"error": "bulunamadı / not found"})

    def add(self, data):
        e = {k: clean(data.get(k), n) for k, n in LIMITS.items()}
        if not e["ad"] or data.get("durum") not in DURUMLAR:
            return self._send(400, {"error": "Ad ve durum gerekli / name and status required"})
        kod = f"{secrets.randbelow(10**6):06d}"
        with lock:
            if self.limited(recent):
                return self._send(429, {"error": "Çok fazla kayıt, biraz bekleyin / too many entries, wait a bit"})
            e.update(id=secrets.token_hex(6), durum=data["durum"], zaman=datetime.now().astimezone().isoformat(timespec="seconds"),
                     kod=hashlib.sha256(kod.encode()).hexdigest(), ara=norm(" ".join((e["ad"], e["yer"], e["mesaj"]))))
            entries.append(e)
            del entries[:-MAX_ENTRIES]
            save(entries)
        self._send(201, {"id": e["id"], "kod": kod})

    def delete(self, data):
        i, kod = data.get("id"), data.get("kod")
        if not isinstance(i, str) or not isinstance(kod, str):
            return self._send(400, {"error": "Geçersiz istek / bad request"})
        h = hashlib.sha256(kod.strip().encode()).hexdigest()
        with lock:
            # Yanlış kod denemeleri sınırlı, 6 haneli kod tek tek denenemez / wrong codes are rate limited
            if len([t for t in fails.get(self.ip(), []) if time.time() - t < RATE_WINDOW]) >= RATE_N:
                return self._send(429, {"error": "Çok fazla deneme, biraz bekleyin / too many tries, wait a bit"})
            match = [e for e in entries if e["id"] == i and secrets.compare_digest(e["kod"], h)]
            if not match:
                self.limited(fails)
                return self._send(403, {"error": "Kod yanlış / wrong code"})
            entries.remove(match[0])
            save(entries)
        self._send(200, {"ok": True})

    def ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def limited(self, book):
        """Bu cihazın son 10 dakikadaki sayısı sınırda mı; değilse bu isteği sayar. / Counts this request unless over the limit."""
        now = time.time()
        times = [t for t in book.get(self.ip(), []) if now - t < RATE_WINDOW]
        if len(times) >= RATE_N:
            return True
        book[self.ip()] = times + [now]
        return False

    def log_message(self, fmt, *args):
        # Kayıt içerikleri ve IP günlüğe yazılmaz / entries and IPs are not logged
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
