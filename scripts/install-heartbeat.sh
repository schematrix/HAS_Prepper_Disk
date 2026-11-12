#!/usr/bin/env bash
# Heartbeat servisini kurar ya da günceller. Tekrar çalıştırmak güvenlidir;
# mevcut ayarlar soruların varsayılanı olur (Enter = değeri koru).
# Installs or updates the heartbeat service. Safe to re-run; current
# settings become the question defaults (Enter = keep the value).
#
# Kullanım / usage:  sudo ./scripts/install-heartbeat.sh
# Ayar dosyası / settings file:  /etc/has-heartbeat.conf
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF=/etc/has-heartbeat.conf

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }

# shellcheck disable=SC2034
url="" format="params" method="" query="" body=""
warnings=1 metrics=0 box_id="" interval="6h"
headers=()
# shellcheck disable=SC1090,SC1091
[ -f "$CONF" ] && . "$CONF"

clean(){
  local s="$1"
  s=${s//\"/}
  s=${s//\\/}
  printf '%s' "$s"
}

shq(){
  local s="$1"
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

ask(){ 
  local __var="$1" __cur a
  __cur=$(clean "${!1}")
  if ! read -rp "$2 [$__cur]: " a; then
    echo
    echo "Girdi yok, çıkılıyor / no input, exiting" >&2
    exit 1
  fi
  printf -v "$__var" '%s' "$(clean "${a:-$__cur}")"
}

ask_raw(){ 
  local __var="$1" __cur a
  __cur=${!1}
  if ! read -rp "$2 [$__cur]: " a; then
    echo
    echo "Girdi yok, çıkılıyor / no input, exiting" >&2
    exit 1
  fi
  printf -v "$__var" '%s' "${a:-$__cur}"
}

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }

# questions
say "Heartbeat"
echo "Kutu internete çıktığında bu adrese 'çalışıyorum' sinyali yollar."
echo "When the box has internet it sends an 'I am working' signal to this URL."
echo "Enter = koru/değiştirme, 'off' = kapat / Enter = keep current, 'off' = disable"
ask url "Heartbeat URL ('off' = kapat / disable)"

if [ -z "$url" ] || [ "$url" = off ] || [ "$url" = kapat ]; then
  url=""
  hlist=""
  for h in "${headers[@]}"; do hlist+=" $(shq "$h")"; done
  {
    printf '# HAS_PrepperDisk heartbeat (kapalı / disabled)\n'
    printf 'url=""\n'
    printf 'format=%s\nmethod=%s\n' "$(shq "$format")" "$(shq "$method")"
    printf 'headers=(%s)\n' "${hlist# }"
    printf 'query=%s\nbody=%s\n' "$(shq "$query")" "$(shq "$body")"
    printf 'warnings=%s\nmetrics=%s\n' "$warnings" "$metrics"
    printf 'box_id="%s"\ninterval="%s"\n' "$box_id" "$interval"
  } > "$CONF"
  chmod 600 "$CONF"
  if systemctl list-unit-files has-heartbeat.timer --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now has-heartbeat.timer >/dev/null
    rm -f /etc/systemd/system/has-heartbeat.service /etc/systemd/system/has-heartbeat.timer
    systemctl daemon-reload
    say "Heartbeat kapatıldı / heartbeat disabled"
  else
    say "Heartbeat kurulmadı / heartbeat not installed"
  fi
  exit 0
fi

while :; do
  ask format "Biçim / format (params=healthchecks.io, Uptime Kuma etc...) (json=Discord, Telegram etc...)"
  case "$format" in params|json) break;; *) echo "params ya da json yazın / enter params or json";; esac
done
while :; do
  ask warnings "Disk uyarıları yollansın mı / send disk warnings (1/0)"
  case "$warnings" in 1|0) break;; *) echo "1 ya da 0";; esac
done
while :; do
  ask metrics "Metrikler yollansın mı (uptime, disk, sıcaklık) / send metrics (1/0)"
  case "$metrics" in 1|0) break;; *) echo "1 ya da 0";; esac
done
ask box_id "Kutu etiketi / box label (isteğe bağlı / optional)"
while :; do
  ask interval "Aralık / interval"
  case "$interval" in *[!0-9smhdw]*) ;; *) case "$interval" in *[smhdw]) break;; esac;; esac
  echo "systemd süresi yazın, örn. 6h / enter a systemd span, e.g. 6h"
done

# customization
say "Tam özelleştirme / full customization (boş bırakılırsa format kullanılır)"
echo "Değişkenler / variables: {status} {msg} {box} {uptime} {disk} {cpu}"
while :; do
  ask method "HTTP yöntemi / method (GET, POST etc...; boş = otomatik / empty = auto)"
  case "$method" in
    '') break;;
    *[!A-Za-z]*) ;;
    *) break;;
  esac
done

if [ ${#headers[@]} -gt 0 ]; then
  echo "Mevcut header'lar / current headers:"
  i=1
  for h in "${headers[@]}"; do echo "  $i. $h"; i=$(( i + 1 )); done
  read -rp "Korunsun mu? Enter=koru, h=yeniden gir / keep? Enter=keep, h=re-enter: " a || a=""
  [ "$a" = h ] && headers=()
fi
while :; do
  read -rp "  header ekle (bitirmek için boş Enter) / add header (empty Enter to finish): " h || h=""
  [ -z "$h" ] && break
  headers+=("$h")
done

ask_raw query "Sorgu şablonu / query template, örn. durum={status}&mesaj={msg}"
ask_raw body "Gövde şablonu / body template, örn. {\"durum\":\"{status}\",\"mesaj\":\"{msg}\"}"

hlist=""
for h in "${headers[@]}"; do hlist+=" $(shq "$h")"; done
{
  printf '# HAS_PrepperDisk heartbeat ayarları / settings\n'
  printf '# Düzenlenebilir / editable: url, format, method, headers, query, body,\n'
  printf '# warnings, metrics, box_id. Aralık için betiği tekrar çalıştır /\n'
  printf '# re-run install-heartbeat.sh for interval.\n'
  printf 'url="%s"\n' "$url"
  printf 'format=%s\n' "$(shq "$format")"
  printf 'method=%s\n' "$(shq "$method")"
  printf 'headers=(%s)\n' "${hlist# }"
  printf 'query=%s\n' "$(shq "$query")"
  printf 'body=%s\n' "$(shq "$body")"
  printf 'warnings=%s\nmetrics=%s\n' "$warnings" "$metrics"
  printf 'box_id="%s"\ninterval="%s"\n' "$box_id" "$interval"
} > "$CONF"
chmod 600 "$CONF"

# systemd units
for u in has-heartbeat.service has-heartbeat.timer; do
  sed -e "s#@REPO@#$REPO#g" -e "s#@INTERVAL@#$interval#g" "$REPO/saglik/$u" > "/etc/systemd/system/$u"
  chmod 644 "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now has-heartbeat.timer >/dev/null

say "Kuruldu / installed"
echo "Ayar / settings:   $CONF"
echo "Test için / to test now:"
echo "  sudo $REPO/scripts/heartbeat.sh"
echo "Kayıtlar / logs:"
echo "  journalctl -u has-heartbeat.service"
echo "Değiştirmek için tekrar çalıştır / to change, re-run:"
echo "  sudo $REPO/scripts/install-heartbeat.sh"
echo "İlk sinyal şimdi gönderiliyor / sending the first signal now:"
"$REPO/scripts/heartbeat.sh"
