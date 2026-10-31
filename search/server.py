#!/usr/bin/env python3
"""HAS_PrepperDisk semantik arama servisi.

Kiwix'in kelime eşleşmesinin bulamadığı soruları ("suyu nasıl arıtırım")
Cevher Nüve embedding'leriyle yanıtlar. Sonuçlar Kiwix URL'leridir.

Kullanım / usage:
    python3 -m search.server --index /library/index --model /library/models/cevher-nuve --port 8089
"""
import argparse
import json
import re
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .embedder import DEFAULT_MODEL, Embedder
from .index import SearchIndex

# Kiwix, ZIM yolunu /kiwix/content/<zim>/<makale> olarak sunar.
KIWIX_CONTENT = "/kiwix/content"


def kiwix_url(zim_name, path):
    zim = re.sub(r"_\d{4}-\d{2}[a-z]?\.zim$", "", zim_name)
    return f"{KIWIX_CONTENT}/{zim}/{urllib.parse.quote(path)}"


class SearchService:
    def __init__(self, index_dir, model_dir):
        started = time.time()
        self.index = SearchIndex(index_dir)
        self.embedder = Embedder(model_dir)
        self.ready_seconds = round(time.time() - started, 2)

    def search(self, query, k=10):
        started = time.perf_counter()
        hits = self.index.search(self.embedder.encode(query, role="query")[0], k=k)
        for h in hits:
            h["url"] = kiwix_url(h["zim"], h["path"])
        return {"query": query, "hits": hits, "ms": round((time.perf_counter() - started) * 1000, 1)}

    def stats(self):
        return {
            "documents": len(self.index.docs),
            "windows": 0 if self.index.vecs is None else int(len(self.index.vecs)),
            "zims": sorted(self.index.zims),
            "ready_seconds": self.ready_seconds,
        }


def make_handler(service):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, payload, status=200):
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(url.query)
            if url.path == "/health":
                return self._send({"ok": True, **service.stats()})
            if url.path == "/search":
                query = (qs.get("q") or [""])[0].strip()
                if not query:
                    return self._send({"error": "q parametresi gerekli"}, 400)
                try:
                    k = min(int((qs.get("k") or ["10"])[0]), 50)
                except ValueError:
                    return self._send({"error": "k sayı olmalı / k must be a number"}, 400)
                return self._send(service.search(query, k=k))
            self._send({"error": "not found"}, 404)

        def log_message(self, fmt, *args):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--index", default="/library/index")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--port", type=int, default=8089)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    if not Path(args.index).exists():
        sys.exit(f"İndeks yok / no index: {args.index} — önce ./scripts/build-index.sh çalıştır")
    service = SearchService(args.index, args.model)
    stats = service.stats()
    print(f"İndeks yüklendi: {stats['documents']} makale, {stats['windows']} pencere, {stats['ready_seconds']} sn")
    print(f"Dinleniyor: http://{args.host}:{args.port}/search?q=...")
    ThreadingHTTPServer((args.host, args.port), make_handler(service)).serve_forever()


if __name__ == "__main__":
    main()
