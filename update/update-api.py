#!/usr/bin/env python3
"""HAS_PrepperDisk güncelleme butonu: POST http://box.lan/guncelleme/  {"ids": [...]}

Ana sayfadaki "Güncelle" butonu buraya istek atar; yönetici şifresi gerekir. Servis yetkisiz bir kullanıcıyla çalışır ve
hiçbir şey indirmez: seçimi updates.json ve usb.json'a göre denetleyip istek dosyasına yazar, indirmeyi
has-update-apply.path (root) başlatır.

The homepage "Güncelle" button posts here; the admin password is required. The service runs unprivileged and downloads nothing:
it checks the selection against updates.json and usb.json and writes the request file; has-update-apply.path
(root) starts the download.
"""
import hashlib
import hmac
import json
import os
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEB = os.environ.get("WEB", "/library/www/html")
UPDATES = os.path.join(WEB, "home", "updates.json")
USB = os.path.join(WEB, "home", "usb.json")
STATUS = os.path.join(WEB, "home", "update-status.json")
REQUEST = os.environ.get("REQUEST", "/run/has-update/request")
PORT = int(os.environ.get("PORT", "8097"))
# Şifrenin tuzlu PBKDF2 özeti; systemd LoadCredential ile gelir. / salted PBKDF2 hash of the password, via LoadCredential.
ADMIN = os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/etc/has-update"), "admin")
# Aynı cihazdan 10 dakikada en fazla 5 yanlış şifre / at most 5 wrong passwords per device per 10 minutes
RATE_N, RATE_WINDOW = 5, 600

lock = threading.Lock()
fails = defaultdict(list)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def password_ok(pw):
    try:
        with open(ADMIN, encoding="utf-8") as f:
            salt, h = f.read().split()
    except (OSError, ValueError):
        return False
    return hmac.compare_digest(hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), 200000).hex(), h)


def running():
    # auto-update.sh indirirken durumu 3 sn'de bir yazar; 2 dk sessizse yarıda kalmıştır.
    # auto-update.sh rewrites the status every 3 s while downloading; 2 min of silence means it died.
    if os.path.exists(REQUEST):
        return True
    try:
        fresh = time.time() - os.path.getmtime(STATUS) < 120
    except OSError:
        return False
    return fresh and read_json(STATUS).get("state") == "running"


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # Yalnızca JSON: başka bir sitenin bu isteği kullanıcının tarayıcısından atması CORS ön kontrolüne takılır.
        # JSON only: another site cannot send this from a visitor's browser without a CORS preflight we never answer.
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            return self._send(415, {"error": "application/json gerekli / required"})
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 4096)
            data = json.loads(self.rfile.read(length))
            ids, pw = data["ids"], data.get("sifre")
        except (ValueError, KeyError, TypeError):
            return self._send(400, {"error": "Geçersiz istek / bad request"})
        ip, now = self.headers.get("X-Real-IP") or self.client_address[0], time.time()
        with lock:
            fails[ip] = [t for t in fails[ip] if now - t < RATE_WINDOW]
            if len(fails[ip]) >= RATE_N:
                return self._send(429, {"error": "Çok fazla yanlış şifre, biraz bekleyin / too many wrong passwords, wait a bit"})
        if not isinstance(pw, str) or not password_ok(pw):
            with lock:
                fails[ip].append(now)
            return self._send(403, {"error": "Şifre yanlış / wrong password"})
        if running():
            return self._send(409, {"error": "Güncelleme zaten sürüyor / an update is already running"})
        items = read_json(UPDATES).get("items", []) + read_json(USB).get("items", [])
        allowed = {i.get("id") for i in items if i.get("fits")}
        if not isinstance(ids, list) or not ids or not all(isinstance(i, str) and i in allowed for i in ids):
            return self._send(400, {"error": "Seçim geçersiz ya da diskte yer yok / invalid selection or no space"})
        tmp = REQUEST + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(dict.fromkeys(ids)) + "\n")
        os.replace(tmp, REQUEST)
        self._send(202, {"ok": True})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.headers.get("X-Real-IP") or self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
