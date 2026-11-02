#!/usr/bin/env bash
# HAS_PrepperDisk ana sayfasını Internet-in-a-Box'a kurar (eskisinin yedeğini alır).
# Installs the HAS_PrepperDisk homepage into Internet-in-a-Box (backs up the old one).
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/www/home"
DST=/library/www/html/home

[ -d "$DST" ] || { echo "$DST yok. Önce Internet-in-a-Box'ı kur / install Internet-in-a-Box first" >&2; exit 1; }

if [ -f "$DST/index.html" ] && [ ! -f "$DST/index.html.iiab-original" ]; then
  cp "$DST/index.html" "$DST/index.html.iiab-original"
fi
cp "$SRC/index.html" "$SRC/search.html" "$DST/"
echo "Ana sayfa kuruldu / homepage installed: http://box.lan/home"
echo "Geri almak için / to restore: sudo cp $DST/index.html.iiab-original $DST/index.html"

# Anlamca arama servisi yalnızca indeks kurulduysa çalışır / search service only when indexed
if [ -d /library/index ] && [ -f /library/models/cevher-nuve/onnx/model.onnx ]; then
  # Hedef klasörün kendisine kopyala: "cp -r search /library/search" ikinci çalıştırmada
  # /library/search/search yaratıyordu ve "python3 -m search.server" modülü bulamıyordu.
  install -d /library/search
  cp -r "$ROOT/search/." /library/search/
  # İkinci çalıştırmada yanlış kopyalanmış eski klasör kalmasın.
  rm -rf /library/search/search
  find /library/search -name __pycache__ -prune -exec rm -rf {} +
  id -u semantic-search >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin semantic-search
  chmod o+rx /library /library/search /library/index
  chmod -R o+rX /library/search /library/index /library/models/cevher-nuve
  cp "$ROOT/config/semantic-search.service" /etc/systemd/system/semantic-search.service
  cp "$ROOT/config/semantic-search-nginx.conf" /etc/nginx/conf.d/semantic-search.conf
  nginx -t && systemctl reload nginx
  systemctl daemon-reload
  systemctl enable --now semantic-search
  echo "Anlamca arama servisi kuruldu / semantic search service installed: /search/api/search"
else
  echo "Anlamca arama kurulmadı (indeks yok) / semantic search skipped (no index): sudo ./scripts/build-index.sh"
fi
