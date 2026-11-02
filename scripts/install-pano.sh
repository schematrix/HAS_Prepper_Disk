#!/usr/bin/env bash
# Güvendeyim panosunu ve duyuru alanını kurar. Tekrar çalıştırmak güvenlidir.
# Installs the "I'm safe" board and the homepage announcement. Safe to re-run.
#
# Kullanım / usage:  sudo ./scripts/install-pano.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/pano"
NGINX_CONF=/etc/nginx/conf.d/has-pano-nginx.conf

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./scripts/install-pano.sh"
[ -d /etc/nginx/conf.d ] || die "nginx bulunamadı. Önce / install first:  sudo ./install.sh"

install -d -m 755 /opt/has-pano
install -m 644 "$SRC/pano-api.py" /opt/has-pano/
install -m 644 "$SRC/has-pano-api.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable has-pano-api.service >/dev/null
systemctl restart has-pano-api.service

install -m 644 "$SRC/pano-nginx.conf" "$NGINX_CONF"
if nginx -t 2>/dev/null; then
  systemctl reload nginx
else
  rm -f "$NGINX_CONF"
  nginx -t || true
  die "nginx ayarı hatalı, geri alındı / nginx config failed and was removed"
fi

cat <<EOF
Güvendeyim panosu kuruldu / board installed: http://box.lan/home/guvendeyim.html
Duyuru / announcement:  sudo ./scripts/pano.sh duyuru "metin"
Tüm kayıtları sil / wipe: sudo ./scripts/pano.sh temizle
EOF
