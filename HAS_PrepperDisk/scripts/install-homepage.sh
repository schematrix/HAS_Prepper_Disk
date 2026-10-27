#!/usr/bin/env bash
# HAS_PrepperDisk ana sayfasını Internet-in-a-Box'a kurar (eskisinin yedeğini alır).
# Installs the HAS_PrepperDisk homepage into Internet-in-a-Box (backs up the old one).
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)/www/home"
DST=/library/www/html/home

[ -d "$DST" ] || { echo "$DST yok. Önce Internet-in-a-Box'ı kur / install Internet-in-a-Box first" >&2; exit 1; }

if [ -f "$DST/index.html" ] && [ ! -f "$DST/index.html.iiab-original" ]; then
  cp "$DST/index.html" "$DST/index.html.iiab-original"
fi
cp "$SRC/index.html" "$DST/index.html"
echo "Ana sayfa kuruldu / homepage installed: http://box.lan/home"
echo "Geri almak için / to restore: sudo cp $DST/index.html.iiab-original $DST/index.html"
