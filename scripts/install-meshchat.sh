#!/usr/bin/env bash
# Mesh sohbet köprüsünü kurar: USB'ye takılı Meschy / Meshtastic cihazını
# http://box.lan/mesh/ adresinde tarayıcıdan kullanılabilir yapar.
# Installs the mesh chat bridge: makes a USB-attached Meschy / Meshtastic node
# usable from a browser at http://box.lan/mesh/.
#
# İnternet gerekir (meshtastic Python paketi indirilir). Tekrar çalıştırmak güvenlidir.
# Needs internet (downloads the meshtastic Python package). Safe to re-run.
#
# Kullanım / usage:  sudo ./scripts/install-meshchat.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/mesh"
APP=/opt/has-meshchat
DATA=/library/meshchat
NGINX_CONF=/etc/nginx/conf.d/meshchat-nginx.conf
DEFAULTS=/etc/default/has-meshchat

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./scripts/install-meshchat.sh"
[ -d /etc/nginx/conf.d ] || die "nginx bulunamadı. Önce / install first:  sudo ./install.sh"

say "1/5 Paketler / packages"
apt-get install -y python3-venv >/dev/null
id meshchat >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin meshchat
usermod -aG dialout meshchat

say "2/5 Uygulama / application -> $APP"
install -d -m 755 "$APP" "$APP/static"
install -m 644 "$SRC/meshchat.py" "$SRC/requirements.txt" "$APP/"
install -m 644 "$SRC/static/index.html" "$APP/static/"
if [ ! -x "$APP/venv/bin/python" ]; then
  python3 -m venv "$APP/venv"
fi
"$APP/venv/bin/pip" install --quiet --upgrade pip
"$APP/venv/bin/pip" install --quiet -r "$APP/requirements.txt" \
  || die "meshtastic indirilemedi. İnternet bağlantısını kontrol et / could not download meshtastic, check the internet connection"

say "3/5 Veri klasörü ve ayarlar / data folder and settings"
install -d -m 750 -o meshchat -g meshchat "$DATA"
if [ ! -f "$DEFAULTS" ]; then
  install -m 644 "$SRC/has-meshchat.default" "$DEFAULTS"
  echo "Ayarlar / settings: $DEFAULTS"
else
  echo "Mevcut ayarlar korundu / kept existing settings: $DEFAULTS"
fi

say "4/5 Servis / service"
install -m 644 "$SRC/has-meshchat.service" /etc/systemd/system/has-meshchat.service
systemctl daemon-reload
systemctl enable has-meshchat >/dev/null
systemctl restart has-meshchat

say "5/5 nginx (/mesh/)"
install -m 644 "$SRC/meshchat-nginx.conf" "$NGINX_CONF"
if nginx -t 2>/dev/null; then
  systemctl reload nginx
else
  rm -f "$NGINX_CONF"
  nginx -t || true
  die "nginx ayarı hatalı, geri alındı / nginx config failed and was removed"
fi

# Ana sayfadaki "Mesh Sohbet" bölümü için güncel ana sayfayı kur.
# Install the current homepage so it shows the "Mesh Sohbet" entry.
if [ -d /library/www/html/home ]; then
  "$REPO/scripts/install-homepage.sh"
fi

# ModemManager, Meshtastic seri portunu kurcalayıp bağlantıyı bozabilir.
# ModemManager may probe the Meshtastic serial port and break the connection.
if systemctl is-active --quiet ModemManager 2>/dev/null; then
  echo
  echo "Uyarı / warning: ModemManager çalışıyor. Bağlantı sorunu olursa / is running. If the radio keeps disconnecting:"
  echo "  sudo systemctl disable --now ModemManager"
fi

sleep 3
say "Bitti / done"
DEVS=$(shopt -s nullglob; echo /dev/ttyACM* /dev/ttyUSB*)
if [ -n "$DEVS" ]; then
  echo "Bulunan seri cihazlar / serial devices found: $DEVS"
else
  echo "Henüz seri cihaz yok. Meschy'yi USB 2.0 (siyah) porta tak / no serial device yet, plug Meschy into a black USB 2.0 port"
fi
cat <<EOF
Mesh sohbet / mesh chat:  http://box.lan/mesh/
Durum / status:           systemctl status has-meshchat
Kayıtlar / logs:          journalctl -u has-meshchat -f
EOF
