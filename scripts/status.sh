#!/usr/bin/env bash
# HAS_PrepperDisk sağlık kontrolü: disk, servisler, hotspot, içerikler, güç ve sıcaklık.
# Health check: disk, services, hotspot, content, power and temperature.
# Sadece okur, hiçbir şeyi değiştirmez. sudo gerekmez.
# Read-only, changes nothing. No sudo needed.
#
# Kullanım / usage:  ./scripts/status.sh [config-dosyası]
# Çıkış kodu / exit code:  0 = sorun yok / all good,  1 = en az bir sorun / at least one problem
set -uo pipefail
shopt -s nullglob

CONF="${1:-$(cd "$(dirname "$0")/.." && pwd)/config/content.conf}"
ZIMS=/library/zims/content
LIBXML=/library/zims/library.xml
problems=0

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok(){ printf '  OK  %s\n' "$*"; }
info(){ printf '  --  %s\n' "$*"; }
bad(){ printf '  !!  %s\n' "$*"; problems=$((problems+1)); }
has(){ command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- disk
say "Disk"
mps=(/)
if mountpoint -q /library 2>/dev/null; then
  ok "/library ayrı diskte / is on its own disk ($(findmnt -no SOURCE /library))"
  mps+=(/library)
else
  bad "/library ayrı bir disk değil, içerikler SD karta yazılır / is not a separate disk, content goes to the SD card"
fi
for mp in "${mps[@]}"; do
  read -r size used avail pct < <(df -h --output=size,used,avail,pcent "$mp" | tail -1)
  msg="$mp: $used / $size dolu / used, $avail boş / free ($pct)"
  if [ "${pct%\%}" -ge 90 ]; then bad "$msg"; else ok "$msg"; fi
done

# ---------------------------------------------------------------- servisler
say "Servisler / services"
if has systemctl; then
  for svc in nginx kiwix-serve hostapd dnsmasq kolibri; do
    if ! systemctl list-unit-files "$svc.service" --no-legend 2>/dev/null | grep -q .; then
      info "$svc kurulu değil / not installed"
      continue
    fi
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$state" = active ]; then ok "$svc"
    else bad "$svc: $state  (kayıt / log: sudo journalctl -u $svc -n 50)"; fi
  done
else
  info "systemctl yok / not found"
fi

# ---------------------------------------------------------------- hotspot
say "Hotspot"
if has iw; then
  ap=$(iw dev 2>/dev/null | awk '$1=="Interface"{i=$2} $1=="type" && $2=="AP"{print i; exit}')
  if [ -n "$ap" ]; then
    ssid=$(iw dev "$ap" info 2>/dev/null | awk '$1=="ssid"{$1=""; sub(/^ /,""); print; exit}')
    if stations=$(iw dev "$ap" station dump 2>/dev/null); then
      clients=$(grep -c '^Station' <<<"$stations")
    else
      clients="?"
    fi
    ok "$ap yayında / broadcasting: \"$ssid\", bağlı cihaz / clients: $clients"
  else
    bad "hiçbir arayüz hotspot modunda değil / no interface in AP mode (README: Sorun giderme / Troubleshooting)"
  fi
else
  info "iw yok / not found"
fi
if has ip && ip link show br0 >/dev/null 2>&1; then
  br=$(ip -br link show br0 | awk '{print $2}')
  if [ "$br" = UP ]; then ok "br0 $br"
  else bad "br0 $br: hotspot köprüsü kapalı / hotspot bridge is down (README: Sorun giderme / Troubleshooting)"; fi
fi

# ---------------------------------------------------------------- web
say "Web"
if has curl; then
  for url in http://localhost/home/ http://localhost/kiwix/; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url")
    case "$code" in
      2*|3*) ok "$url ($code)";;
      *)     bad "$url yanıt vermiyor / not responding ($code)";;
    esac
  done
else
  info "curl yok / not found"
fi

# ---------------------------------------------------------------- içerik
say "İçerik / content"
if [ ! -f "$CONF" ]; then
  bad "$CONF bulunamadı / not found"
elif [ ! -d "$ZIMS" ]; then
  bad "$ZIMS yok. İçerik indir / download content: sudo ./scripts/download-content.sh"
else
  present=0; missing=()
  while read -r folder prefix _; do
    case "$folder" in ''|\#*) continue;; esac
    found=("$ZIMS/${prefix}"_[0-9][0-9][0-9][0-9]-[0-9][0-9]*.zim)
    if [ ${#found[@]} -gt 0 ]; then present=$((present+1)); else missing+=("$prefix"); fi
  done < "$CONF"

  info "$(du -sh "$ZIMS" 2>/dev/null | cut -f1) $ZIMS"
  if [ ${#missing[@]} -eq 0 ]; then
    ok "content.conf: $present/$present ZIM var / present"
  else
    bad "content.conf: $present/$((present+${#missing[@]})) ZIM var / present. Eksik / missing:"
    printf '        %s\n' "${missing[@]}"
    info "indirmek için / to download: sudo ./scripts/download-content.sh"
  fi

  parts=("$ZIMS"/*.part)
  if [ ${#parts[@]} -gt 0 ]; then
    bad "${#parts[@]} yarım indirme / unfinished download(s). Devam için / to resume: sudo ./scripts/download-content.sh"
  fi

  # Diskte olup Kiwix kütüphanesinde olmayan ZIM'ler ana sayfada görünmez.
  # ZIMs on disk but missing from the Kiwix library do not show up on the homepage.
  if [ -f "$LIBXML" ]; then
    unlisted=()
    for z in "$ZIMS"/*.zim; do
      grep -qF "${z##*/}" "$LIBXML" || unlisted+=("${z##*/}")
    done
    if [ ${#unlisted[@]} -eq 0 ]; then
      ok "tüm ZIM'ler Kiwix kütüphanesinde / all ZIMs are in the Kiwix library"
    else
      bad "${#unlisted[@]} ZIM Kiwix kütüphanesinde değil / not in the Kiwix library:"
      printf '        %s\n' "${unlisted[@]}"
      info "düzeltmek için / to fix: sudo iiab-make-kiwix-lib"
    fi
  else
    bad "$LIBXML yok / not found. Çalıştır / run: sudo iiab-make-kiwix-lib"
  fi
fi

# ---------------------------------------------------------------- güç ve sıcaklık
say "Güç ve sıcaklık / power and temperature"
has vcgencmd || [ -r /sys/class/thermal/thermal_zone0/temp ] || info "okunamadı (Raspberry Pi değil mi?) / not available (not a Raspberry Pi?)"
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  c=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  if [ "$c" -ge 80 ]; then bad "CPU ${c}°C: çok sıcak, soğutucuyu kontrol et / too hot, check the cooler"
  else ok "CPU ${c}°C"; fi
fi
if has vcgencmd; then
  if t=$(vcgencmd get_throttled 2>/dev/null) && [ -n "${t#*=}" ]; then
    v=$(( ${t#*=} ))
    if [ "$v" -eq 0 ]; then
      ok "düşük voltaj ya da yavaşlama yok / no under-voltage or throttling ($t)"
    else
      (( v & 0x1 ))     && bad "ŞU AN düşük voltaj / under-voltage NOW: 5V/5A adaptör kullan / use a 5V/5A supply"
      (( v & 0x10000 )) && bad "açılıştan beri düşük voltaj oldu / under-voltage occurred since boot"
      (( v & 0x4 ))     && bad "şu an yavaşlatılıyor / currently throttled"
      (( v & 0x8 ))     && bad "şu an sıcaklık sınırında / soft temperature limit active"
      (( v & 0xE0000 )) && bad "açılıştan beri yavaşlama ya da sıcaklık sınırı oldu / throttling or temperature limit occurred since boot"
      info "$t"
    fi
  else
    info "vcgencmd okunamadı / could not read vcgencmd (video grubunda mısın? / are you in the video group?)"
  fi
  if volt=$(vcgencmd pmic_read_adc EXT5V_V 2>/dev/null) && [[ $volt == *=*V ]]; then
    info "giriş voltajı / input voltage: ${volt#*=}"
  fi
fi

# ---------------------------------------------------------------- sonuç
say "Sonuç / result"
if [ "$problems" -eq 0 ]; then
  echo "Her şey yolunda / all good"
  exit 0
fi
echo "$problems sorun bulundu / problem(s) found"
exit 1
