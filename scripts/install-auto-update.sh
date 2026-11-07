#!/usr/bin/env bash
# Otomatik güncellemeyi kurar: internet gelince yeni sürüm kontrolü, ana sayfada bildirim ve
# "Güncelle" butonu. Hiçbir şey onaysız indirilmez. Tekrar çalıştırmak güvenlidir.
# Installs automatic updates: a check for newer versions when internet appears, a homepage notice
# and an update button. Nothing is downloaded without approval. Safe to re-run.
#
# Güncelleme butonu iiab-admin şifresini ister / the update button asks for the iiab-admin password.
#
# Kullanım / usage:  sudo ./scripts/install-auto-update.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/update"
APP=/opt/has-update
NGINX_CONF=/etc/nginx/conf.d/has-update-nginx.conf
UNITS="has-update-check.service has-update-check.timer has-update-apply.service has-update-apply.path has-update-api.service has-update-admin.service has-update-admin.path has-usb@.service"

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./scripts/install-auto-update.sh"
[ -d /etc/nginx/conf.d ] || die "nginx bulunamadı. Önce / install first:  sudo ./install.sh"

install -d -m 755 "$APP"
install -m 644 "$SRC/update-api.py" "$APP/"
install -m 755 "$SRC/admin-hash.sh" "$APP/"
# Servisler betikleri bu repodan çalıştırır, config/content.conf değişiklikleri de böylece geçerli olur.
# The services run the scripts from this repo, so edits to config/content.conf apply too.
for u in $UNITS; do
  sed "s#@REPO@#$REPO#g" "$SRC/$u" > "/etc/systemd/system/$u"
  chmod 644 "/etc/systemd/system/$u"
done

if [ -d /etc/NetworkManager/dispatcher.d ]; then
  install -m 755 "$SRC/90-has-update" /etc/NetworkManager/dispatcher.d/90-has-update
else
  echo "Uyarı / warning: NetworkManager yok, kontrol yalnızca günde bir yapılır / no NetworkManager, checks run daily only"
fi

install -m 644 "$SRC/99-has-usb.rules" /etc/udev/rules.d/99-has-usb.rules
udevadm control --reload
ln -sfn /run/has-usb/usb.json /library/www/html/home/usb.json

systemctl daemon-reload
systemctl enable --now has-update-api.service has-update-apply.path has-update-admin.path has-update-check.timer >/dev/null
systemctl restart has-update-api.service

install -m 644 "$SRC/update-nginx.conf" "$NGINX_CONF"
if nginx -t 2>/dev/null; then
  systemctl reload nginx
else
  rm -f "$NGINX_CONF"
  nginx -t || true
  die "nginx ayarı hatalı, geri alındı / nginx config failed and was removed"
fi

"$REPO/scripts/install-homepage.sh"
systemctl start --no-block has-update-check.service

cat <<EOF
Otomatik güncelleme kuruldu / automatic updates installed.
Yeni sürüm bulununca ana sayfada görünür / newer versions show up on the homepage: http://box.lan/home
Elle kontrol / check now:  sudo ./scripts/auto-update.sh --check --force
Kayıtlar / logs:           journalctl -u has-update-check -u has-update-apply
EOF
