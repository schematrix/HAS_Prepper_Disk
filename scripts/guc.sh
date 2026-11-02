#!/usr/bin/env bash
# Güç tasarrufu: elektrik yokken kutu powerbank ya da aküyle daha uzun çalışsın.
# Kiwix, ana sayfa, harita, hotspot ve HAS servisleri hep açık kalır; yalnızca gerekmeyenler kapanır.
# Power saving for running on a power bank or battery. Kiwix, the homepage, maps, the hotspot and
# the HAS services always stay on; only optional services stop.
#
# Kullanım / usage:
#   sudo ./scripts/guc.sh tasarruf   gereksiz servisleri kapat, işlemciyi kıs / stop optional services, cap the CPU
#   sudo ./scripts/guc.sh normal     kapattıklarını geri aç / restore what tasarruf stopped
#   ./scripts/guc.sh durum           mod, kapalı servisler, Pi'nin çektiği güç / mode, stopped services, board power
set -euo pipefail

# Afette gerekmeyen, boşta da kaynak harcayan servisler / services not needed in a disaster that use resources when idle
OPTIONAL="kolibri sugarizer mongodb calibre-web transmission-daemon tailscaled bluetooth hciuart cups cups-browsed"
CPU_MAX_KHZ=1500000
STATE=/var/lib/has-guc
JSON=/library/www/html/home/guc.json

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
need_root(){ [ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo"; }

cpu_cap(){
  local p max
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -w "$p/scaling_max_freq" ] || continue
    max=$(cat "$p/cpuinfo_max_freq")
    [ "$1" = on ] && [ "$max" -gt "$CPU_MAX_KHZ" ] && max=$CPU_MAX_KHZ
    echo "$max" > "$p/scaling_max_freq"
  done
}

write_json(){
  local names=() s
  while read -r s _; do
    case "$s" in
      kolibri) names+=('"Kolibri"');;
      sugarizer) names+=('"Sugarizer"');;
      calibre-web) names+=('"Calibre-Web"');;
    esac
  done < "$STATE/kapatilan"
  printf '{"mod":"tasarruf","kapali":[%s]}\n' "$(IFS=,; echo "${names[*]}")" > "$JSON.tmp"
  chmod 644 "$JSON.tmp" && mv "$JSON.tmp" "$JSON"
}

case "${1:-}" in
  tasarruf)
    need_root
    install -d -m 755 "$STATE"
    touch "$STATE/kapatilan"
    for s in $OPTIONAL; do
      systemctl cat "$s.service" >/dev/null 2>&1 || continue
      if systemctl is-enabled --quiet "$s.service" 2>/dev/null || systemctl is-active --quiet "$s.service"; then
        # Açılışta başlayıp başlamadığı da saklanır, normal tam eski haline döndürür
        # Whether it started at boot is kept too, so normal restores exactly the old state
        if ! grep -q "^$s " "$STATE/kapatilan"; then
          if systemctl is-enabled --quiet "$s.service" 2>/dev/null; then was=enabled; else was=disabled; fi
          echo "$s $was" >> "$STATE/kapatilan"
        fi
        systemctl disable --now "$s.service" >/dev/null 2>&1 || true
        echo "Kapatıldı / stopped: $s"
      fi
    done
    if command -v rfkill >/dev/null; then rfkill block bluetooth 2>/dev/null || true; fi
    cpu_cap on
    echo tasarruf > "$STATE/mod"
    [ -d "$(dirname "$JSON")" ] && write_json
    echo "Güç tasarrufu açık / power saving on. Geri almak için / to undo:  sudo ./scripts/guc.sh normal";;
  normal)
    need_root
    [ -f "$STATE/kapatilan" ] && while read -r s was; do
      [ "$was" = enabled ] && systemctl enable "$s.service" >/dev/null 2>&1
      if systemctl start "$s.service"; then echo "Açıldı / started: $s"; else echo "Açılamadı / failed: $s"; fi
    done < "$STATE/kapatilan"
    if command -v rfkill >/dev/null; then rfkill unblock bluetooth 2>/dev/null || true; fi
    cpu_cap off
    rm -f "$STATE/kapatilan" "$STATE/mod" "$JSON"
    echo "Normal mod / normal mode";;
  uygula)
    # Açılışta has-guc.service çalıştırır: işlemci sınırı yeniden başlatınca sıfırlanır
    # Run at boot by has-guc.service: the CPU cap does not survive a reboot
    need_root
    [ "$(cat "$STATE/mod" 2>/dev/null)" = tasarruf ] && cpu_cap on
    exit 0;;
  durum)
    echo "Mod / mode: $(cat "$STATE/mod" 2>/dev/null || echo normal)"
    [ -s "$STATE/kapatilan" ] && echo "Kapalı / stopped: $(cut -d' ' -f1 "$STATE/kapatilan" | tr '\n' ' ')"
    f=/sys/devices/system/cpu/cpufreq/policy0
    [ -r "$f/scaling_max_freq" ] && echo "İşlemci üst sınırı / CPU max: $(( $(cat "$f/scaling_max_freq") / 1000 )) MHz"
    # Pi 5 güç yönetim yongasının ölçtüğü kart gücü; adaptör, USB ve SSD hariç / board power from the Pi 5 PMIC, excluding USB and the SSD
    if command -v vcgencmd >/dev/null && vcgencmd pmic_read_adc >/dev/null 2>&1; then
      vcgencmd pmic_read_adc | awk '
        { split($2, x, "="); n = substr($1, 1, length($1) - 2) }
        $1 ~ /_A$/ { a[n] = x[2] + 0 }
        $1 ~ /_V$/ { v[n] = x[2] + 0 }
        END { for (k in a) if (k in v) w += a[k] * v[k]; printf "Kart gücü / board power: %.2f W\n", w }'
    fi;;
  *)
    sed -n '7,10p' "$0"; exit 2;;
esac
