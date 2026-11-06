#!/usr/bin/env bash
# /library diskinin ve Pi'nin güç kaynağının sağlığına bakar, sorunları ana sayfanın okuduğu disk.json'a yazar.
# Checks the /library disk and the Pi's power supply; problems go to disk.json, shown on the homepage.
#
# Kullanım / usage:  sudo ./scripts/disk-health.sh      (has-disk-health.timer 6 saatte bir çalıştırır / runs every 6 h)
# Ortam / environment:  LIB=/library  WEB=/library/www/html
set -uo pipefail

LIB="${LIB:-/library}"
WEB="${WEB:-/library/www/html}"
OUT="$WEB/home/disk.json"

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }

warn=()
add(){ warn+=("$1"); echo "!! $1"; }

if mountpoint -q "$LIB"; then
  src=$(findmnt -no SOURCE "$LIB")
  case ",$(findmnt -no OPTIONS "$LIB")," in
    *,ro,*) add "Disk salt okunur moda geçmiş. Bu genellikle dosya sistemi hatası demektir; içerikleri yedekleyin.";;
  esac
  errs=$(cat "/sys/fs/ext4/$(basename "$(readlink -f "$src")")/errors_count" 2>/dev/null || echo 0)
  [ "${errs:-0}" -gt 0 ] && add "Dosya sisteminde $errs hata kaydı var. Pi'yi kapatıp diski kontrol edin (fsck)."
  disk=$(lsblk -no PKNAME "$src" | head -1)
  disk=/dev/${disk:-$(basename "$src")}
  if command -v smartctl >/dev/null; then
    smart=$(smartctl -H -A "$disk" 2>&1); rc=$?
    # smartctl çıkış kodu bit 3: disk arızalanıyor, bit 4: ön arıza değerleri eşiğin altında
    # smartctl exit status bit 3: disk failing, bit 4: pre-failure attributes below threshold
    (( rc & 8 )) && add "Disk kendi sağlık testinde ARIZALI çıktı. İçerikleri hemen başka bir diske kopyalayın."
    (( rc & 16 )) && add "Disk arıza öncesi belirtiler gösteriyor. Yedek bir disk hazırlayın."
    used=$(sed -nE 's/^Percentage Used: *([0-9]+)%.*/\1/p' <<<"$smart")
    [ "${used:-0}" -ge 90 ] && add "SSD ömrünün %$used kadarı kullanılmış. Yedek bir disk hazırlayın."
  fi
elif grep -qE '^[^#]\S*\s+/library\s' /etc/fstab; then
  add "SSD /library'ye bağlı değil. Takılı mı? İçerikler görünmeyebilir."
fi

pct=$(df --output=pcent "$LIB" 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${pct:-0}" -ge 95 ] && add "Disk %$pct dolu. Yeni içerik ve güncellemeler için yer kalmadı."

# Raspberry Pi: get_throttled bit 0 şu an düşük voltaj, bit 16 açılıştan beri düşük voltaj oldu.
# Raspberry Pi: get_throttled bit 0 = under-voltage now, bit 16 = under-voltage since boot.
if command -v vcgencmd >/dev/null; then
  t=$(( $(vcgencmd get_throttled | cut -d= -f2) ))
  if (( t & 0x1 )); then
    add "Pi şu anda düşük voltajla çalışıyor (güç kaynağı ya da pil yetersiz). Disk bozulabilir."
  elif (( t & 0x10000 )); then
    add "Açılıştan beri düşük voltaj yaşandı. Güç kaynağını ya da pili kontrol edin."
  fi
fi

items=""
for w in "${warn[@]}"; do items+="${items:+,}\"$w\""; done
cat > "$OUT.tmp" <<EOF
{"checked":"$(date -Is)","warnings":[$items]}
EOF
chmod 644 "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
[ ${#warn[@]} -eq 0 ] && echo "OK disk ve güç sağlıklı / disk and power healthy"
exit 0
