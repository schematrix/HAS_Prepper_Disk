#!/usr/bin/env bash
# HAS_PrepperDisk kurulum betiği / installer
#  1. Internet-in-a-Box ayarlarını hazırlar / prepares Internet-in-a-Box settings
#  2. Internet-in-a-Box'ı kurar / installs Internet-in-a-Box
#  3. HAS_PrepperDisk ana sayfasını kurar / installs the HAS_PrepperDisk homepage
#
# Kurulum sırasında Pi yeniden başlarsa bu betiği tekrar çalıştır.
# If the Pi reboots during install, just run this script again.
#
# Kullanım / usage:  sudo ./install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
VARS=/etc/iiab/local_vars.yml
VARS_TEMPLATE=https://raw.githubusercontent.com/iiab/iiab/master/vars/local_vars_medium.yml

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo: sudo ./install.sh"

# local_vars.yml içinde bir ayarı değiştir ya da ekle / set or add one key
set_var(){
  local key="$1" val="$2"
  sed -i "/^${key}:/d" "$VARS"
  printf '%s: %s\n' "$key" "$val" >> "$VARS"
}

# Wi-Fi değerlerini local_vars.yml'e yazmadan önce denetle / check Wi-Fi values before writing them.
# Değerler "..." içinde yazılır: " ve \ YAML'ı, {{ {% {# Ansible'ı bozar.
# Values are written inside "...": " and \ break the YAML, {{ {% {# break Ansible.
bad_chars(){
  case "$1" in *\"*|*\\*|*'{{'*|*'{%'*|*'{#'*) return 0;; esac
  return 1
}
check_ssid(){
  local bytes; bytes=$(printf '%s' "$1" | LC_ALL=C wc -c)
  [ "$bytes" -le 32 ] || { echo "En fazla 32 bayt (Türkçe harf 2 bayt) / max 32 bytes"; return 1; }
  case "$1" in *[[:cntrl:]]*) echo "Kontrol karakteri olamaz / no control characters"; return 1;; esac
  ! bad_chars "$1" || { echo "\" \\ {{ {% {# kullanılamaz / not allowed"; return 1; }
}
# WPA2: 8-63 karakter, yalnızca İngilizce klavye karakterleri / 8-63 printable ASCII characters
check_pass(){
  ! printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]' || { echo "Yalnızca İngilizce klavye karakterleri (ş, ğ, ı... olmaz) / ASCII only"; return 1; }
  [ "${#1}" -ge 8 ] && [ "${#1}" -le 63 ] || { echo "8-63 karakter olmalı / must be 8-63 characters"; return 1; }
  case "$1" in ' '*|*' ') echo "Başta ya da sonda boşluk olamaz / no leading or trailing spaces"; return 1;; esac
  ! bad_chars "$1" || { echo "\" \\ {{ {% {# kullanılamaz / not allowed"; return 1; }
}

# ---------------------------------------------------------------- 0. kontroller
say "Kontroller / checks"
if ! mountpoint -q /library; then
  echo "Uyarı: /library ayrı bir diske bağlı değil. İçerikler SD karta yazılır."
  echo "Warning: /library is not on a separate disk. Content will go to the SD card."
  echo "SSD için önce / for an SSD first run:  sudo ./scripts/setup-ssd.sh /dev/nvme0n1"
  read -rp "Yine de devam? / Continue anyway? [e/y/N] " a
  case "$a" in e|E|y|Y) ;; *) exit 1;; esac
else
  df -h /library | tail -1
fi

if [ -f /etc/iiab/install-flags/iiab-complete ]; then
  say "Internet-in-a-Box zaten kurulu / already installed"
else
  # ---------------------------------------------------------- 1. ayarlar
  say "1/3 Ayarlar / settings"
  mkdir -p /etc/iiab
  if [ ! -f "$VARS" ]; then
    curl -fsSL "$VARS_TEMPLATE" -o "$VARS" || die "local_vars şablonu indirilemedi / could not download template"
  fi
  cp "$VARS" "$VARS.bak.$(date +%Y%m%d%H%M%S)"

  while read -r line; do
    case "$line" in ''|\#*) continue;; esac
    set_var "${line%%:*}" "$(echo "${line#*:}" | sed 's/^ *//')"
  done < "$REPO/config/iiab-overrides.yml"

  while :; do
    read -rp "Wi-Fi ağ adı / network name [HAS_PrepperDisk]: " SSID
    SSID="${SSID:-HAS_PrepperDisk}"
    check_ssid "$SSID" && break
  done
  while :; do
    IFS= read -rsp "Wi-Fi şifresi / password (8-63 karakter / chars): " PASS; echo
    check_pass "$PASS" || continue
    IFS= read -rsp "Tekrar / again: " PASS2; echo
    [ "$PASS" = "$PASS2" ] && break
    echo "Şifreler aynı değil / passwords do not match"
  done
  set_var host_ssid "\"$SSID\""
  set_var hostapd_password "\"$PASS\""
  echo "Ayarlar yazıldı / settings written: $VARS"

  # ---------------------------------------------------------- 2. IIAB
  say "2/3 Internet-in-a-Box kuruluyor / installing (30-60 dk / min)"
  echo "Pi yeniden başlarsa tekrar çalıştır / if the Pi reboots, run again:  sudo ./install.sh"
  if command -v iiab >/dev/null; then
    iiab
  else
    curl -fsSL https://d.iiab.io/install.txt | bash
  fi
  [ -f /etc/iiab/install-flags/iiab-complete ] || die "Kurulum bitmedi / install not finished. Tekrar çalıştır / run again: sudo ./install.sh"
fi

# -------------------------------------------------------------- 3. ana sayfa
say "3/3 Ana sayfa / homepage"
"$REPO/scripts/install-homepage.sh"

IP=$(hostname -I | awk '{print $1}')
say "Bitti / done"
cat <<EOF
Ana sayfa / homepage:     http://$IP/home   (hotspot üzerinden / via hotspot: http://box.lan/home)
Yönetim / admin console:  http://$IP/admin  (kullanıcı / user: iiab-admin)

Sıradaki adım / next step: içerikleri indir / download content
  sudo ./scripts/download-content.sh
EOF
