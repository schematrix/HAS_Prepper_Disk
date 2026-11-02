#!/usr/bin/env bash
# Otomatik güncellemeyi kurar: internet gelince yeni sürüm kontrolü, ana sayfada bildirim ve
# "Güncelle" butonu. Hiçbir şey onaysız indirilmez. Tekrar çalıştırmak güvenlidir.
# Installs automatic updates: a check for newer versions when internet appears, a homepage notice
# and an update button. Nothing is downloaded without approval. Safe to re-run.
#
# Güncelleme butonu yönetici şifresi ister; ilk kurulumda sorulur, --sifre ile değiştirilir.
# The update button asks for an admin password; set on first install, change it with --sifre.
#
# Kullanım / usage:  sudo ./scripts/install-auto-update.sh [--sifre]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/update"
APP=/opt/has-update
NGINX_CONF=/etc/nginx/conf.d/has-update-nginx.conf
ADMIN=/etc/has-update/admin
UNITS="has-update-check.service has-update-check.timer has-update-apply.service has-update-apply.path has-update-api.service has-usb@.service"

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./scripts/install-auto-update.sh"
[ -d /etc/nginx/conf.d ] || die "nginx bulunamadı. Önce / install first:  sudo ./install.sh"

install -d -m 755 "$APP"
install -m 644 "$SRC/update-api.py" "$APP/"
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

# Şifrenin kendisi değil, tuzlu özeti saklanır / only a salted hash is stored
if [ ! -s "$ADMIN" ] || [ "${1:-}" = --sifre ]; then
  while :; do
    read -rsp "Güncelleme butonu yönetici şifresi / update button admin password (en az 8 / min 8): " P1; echo
    read -rsp "Tekrar / again: " P2; echo
    [ "${#P1}" -ge 8 ] && [ "$P1" = "$P2" ] && break
    echo "Kısa ya da eşleşmiyor / too short or does not match"
  done
  install -d -m 700 /etc/has-update
  printf %s "$P1" | python3 -c 'import hashlib, os, sys
salt = os.urandom(16)
print(salt.hex(), hashlib.pbkdf2_hmac("sha256", sys.stdin.buffer.read(), salt, 200000).hex())' > "$ADMIN.tmp"
  chmod 600 "$ADMIN.tmp" && mv "$ADMIN.tmp" "$ADMIN"
fi

systemctl daemon-reload
systemctl enable --now has-update-api.service has-update-apply.path has-update-check.timer >/dev/null
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
