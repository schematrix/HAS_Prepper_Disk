#!/usr/bin/env bash
# "Telefona indir" sayfasını kurar: telefonlar Kiwix uygulamasını ve içerikleri kutudan indirir.
# Tekrar çalıştırmak güvenlidir.
# Installs the "Telefona indir" page: phones download the Kiwix app and content from the box. Safe to re-run.
#
# Kullanım / usage:  sudo ./scripts/install-telefon.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NGINX_CONF=/etc/nginx/conf.d/has-telefon-nginx.conf

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./scripts/install-telefon.sh"
[ -d /etc/nginx/conf.d ] || die "nginx bulunamadı. Önce / install first:  sudo ./install.sh"

install -d -m 755 /library/www/html/telefon
install -m 644 "$REPO/telefon/telefon-nginx.conf" "$NGINX_CONF"
if nginx -t 2>/dev/null; then
  systemctl reload nginx
else
  rm -f "$NGINX_CONF"
  nginx -t || true
  die "nginx ayarı hatalı, geri alındı / nginx config failed and was removed"
fi

cat <<EOT
Telefona indir sayfası kuruldu / page installed: http://box.lan/home/telefon.html
Kiwix uygulamasını indir / download the Kiwix app:  sudo ./scripts/download-app.sh
EOT
