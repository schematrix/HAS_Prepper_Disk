#!/usr/bin/env bash
# Otomatik güncelleme. Kendiliğinden hiçbir şey indirmez:
#   --check  internet varsa yeni sürümleri bulur, ana sayfanın okuduğu updates.json'a yazar
#   --apply  ana sayfada onaylanan içerikleri indirir, ilerlemeyi update-status.json'a yazar
#   --usb    takılı USB disklerdeki daha yeni ZIM'leri bulur, usb.json'a yazar (internet gerekmez)
# Automatic updates. Never downloads anything on its own:
#   --check  if online, finds newer versions and writes them to updates.json (read by the homepage)
#   --apply  downloads the items approved on the homepage, progress goes to update-status.json
#   --usb    finds newer ZIMs on plugged-in USB drives and writes them to usb.json (no internet needed)
# İndirmeyi download-content.sh ve download-map.sh yapar (SHA-256, yer kontrolü, eski sürümü silme).
# The actual downloads are done by download-content.sh and download-map.sh.
#
# Kullanım / usage:
#   sudo ./scripts/auto-update.sh --check [--force]   --force olmadan 6 saatte birden sık bakmaz / at most every 6 h without --force
#   sudo ./scripts/auto-update.sh --apply [id ...]    id yoksa ana sayfanın istek dosyasını okur / without ids reads the homepage request
#   sudo ./scripts/auto-update.sh --usb [--usb-add|--usb-remove sdX1]   has-usb@.service çağırır / called by has-usb@.service
# Ortam / environment:  WEB=/library/www/html  DEST=/library/zims/content  RESERVE_GB=5  CHECK_HOURS=6
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$REPO/config/content.conf"
WEB="${WEB:-/library/www/html}"
DEST="${DEST:-/library/zims/content}"
RESERVE_GB="${RESERVE_GB:-5}"
CHECK_HOURS="${CHECK_HOURS:-6}"
STATE_DIR="${STATE_DIR:-/var/lib/has-update}"
REQUEST="${REQUEST:-/run/has-update/request}"
LOCK="${LOCK:-/run/lock/has-update.lock}"
UPDATES="$WEB/home/updates.json"
STATUS="$WEB/home/update-status.json"
MAP_META="$WEB/harita/data/map.json"
# usb.json /run altında durur, yeniden başlatınca eski liste kalmaz / lives in /run so a reboot clears a stale list
USB_DIR="${USB_DIR:-/run/has-usb}"
USB_JSON="$USB_DIR/usb.json"
USB_ROOTS="${USB_ROOTS:-$USB_DIR /media}"
BUILDS_URL=https://build-metadata.protomaps.dev/builds.json
BUILD_BASE=https://build.protomaps.com
GB=$((1024 * 1024 * 1024))

mode=""; FORCE=0; ids=(); usbact=""; usbdev=""
for a in "$@"; do
  case "$a" in
    --check|--apply|--usb) mode=$a;;
    --usb-add|--usb-remove) mode=--usb; usbact=$a;;
    --force) FORCE=1;;
    -*) echo "bilinmeyen seçenek / unknown option: $a" >&2; exit 2;;
    *) if [ -n "$usbact" ]; then usbdev=$a; else ids+=("$a"); fi;;
  esac
done
[ -n "$mode" ] || { echo "kullanım / usage: $0 --check [--force] | --apply [id ...] | --usb" >&2; exit 2; }
[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }

# JSON'a yalnızca bu karakterlerden oluşan değerler yazılır, kaçış gerekmez.
# Only values made of these characters reach the JSON, so no escaping is needed.
safe(){ [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
write_json(){ cat > "$1.tmp" && chmod 644 "$1.tmp" && mv "$1.tmp" "$1"; }
field(){ sed -nE "s/.*\"$1\":\"?([^,\"}]*).*/\1/p" <<<"$2"; }

online(){
  local i
  for i in 1 2 3; do
    curl -fsSI -m 20 -o /dev/null https://download.kiwix.org/zim/ && return 0
    sleep 20
  done
  return 1
}

# Telefon paylaşımı gibi kotalı bağlantıları NetworkManager "metered" olarak işaretler.
# NetworkManager marks connections such as phone hotspots as metered.
metered(){
  local dev; dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  if [ -n "$dev" ] && nmcli -t -g GENERAL.METERED device show "$dev" 2>/dev/null | grep -q '^yes'; then echo true; else echo false; fi
}

check(){
  if [ "$FORCE" = 0 ] && [ -f "$STATE_DIR/last-check" ] \
     && [ $(( $(date +%s) - $(stat -c %Y "$STATE_DIR/last-check") )) -lt $((CHECK_HOURS * 3600)) ]; then
    echo "== son kontrol $CHECK_HOURS saatten yeni, atlandı / checked within $CHECK_HOURS h, skipped"; return 0
  fi
  online || { echo "== internet yok, kontrol atlandı / no internet, check skipped"; return 0; }
  echo ">> yeni sürümler aranıyor / looking for newer versions"

  local avail items="" sep="" folder prefix latest size current fits
  avail=$(df -B1 --output=avail "$DEST" | tail -1 | tr -dc '0-9')
  while read -r _ folder prefix latest size; do
    safe "$folder" && safe "$prefix" && safe "$latest" || continue
    current=$(cd "$DEST" && ls "$prefix"_[0-9][0-9][0-9][0-9]-[0-9][0-9]*.zim 2>/dev/null | tail -1)
    [[ "$size" =~ ^[0-9]+$ ]] || size=null
    fits=true; [ "$size" != null ] && [ "$avail" -lt $((size + RESERVE_GB * GB)) ] && fits=false
    items+="$sep"$'\n'"  {\"id\":\"$prefix\",\"kind\":\"zim\",\"folder\":\"$folder\",\"current\":\"$current\",\"latest\":\"$latest\",\"size\":$size,\"fits\":$fits}"
    sep=","
  done < <(CHECK_ONLY=1 DEST="$DEST" "$REPO/scripts/download-content.sh" "$CONF" | grep '^UPDATE ')

  # Harita yalnızca kuruluysa ve daha yeni planet build'i varsa / map only if installed and a newer build exists
  if [ -f "$MAP_META" ]; then
    local name have build bytes mapavail i d
    name=$(sed -nE 's/.*"name": *"([^"]*)".*/\1/p' "$MAP_META")
    have=$(sed -nE 's/.*"build": *"([0-9]{8})".*/\1/p' "$MAP_META")
    bytes=$(sed -nE 's/.*"bytes": *([0-9]+).*/\1/p' "$MAP_META")
    build=$(curl -fsSL -m 60 "$BUILDS_URL" | grep -oE '"key":"[0-9]{8}\.pmtiles"' | grep -oE '[0-9]{8}' | sort | tail -1)
    # builds.json bazı bağlantılardan açılmıyor; o zaman son günlerin dosyası doğrudan sorulur.
    # builds.json is unreachable from some connections; then ask for recent daily files directly.
    if [ -z "$build" ]; then
      for i in $(seq 0 10); do
        d=$(date -u -d "-$i day" +%Y%m%d)
        curl -fsI -m 20 -o /dev/null "$BUILD_BASE/$d.pmtiles" && { build=$d; break; }
      done
    fi
    if safe "$name" && [ -n "$have" ] && [ -n "$build" ] && [ "$build" -gt "$have" ]; then
      # download-map.sh ile aynı kural / same rule as download-map.sh: kesit ~3 GB + pay / extract ~3 GB + headroom
      mapavail=$(df -B1 --output=avail "$WEB" | tail -1 | tr -dc '0-9')
      fits=true; [ "$mapavail" -lt $(((RESERVE_GB + 3) * GB)) ] && fits=false
      items+="$sep"$'\n'"  {\"id\":\"harita\",\"kind\":\"map\",\"name\":\"$name\",\"current\":\"$have\",\"latest\":\"$build\",\"size\":${bytes:-null},\"fits\":$fits}"
    fi
  fi

  write_json "$UPDATES" <<EOF
{"checked":"$(date -Is)","metered":$(metered),"free":$avail,"reserve":$((RESERVE_GB * GB)),"items":[$items
]}
EOF
  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/last-check"
  echo "OK $(grep -c '"id"' "$UPDATES") yeni sürüm / newer versions -> $UPDATES"
}

# USB diski salt okunur bağlar. fstab'daki ya da zaten bağlı diskler (ör. USB'li SSD) atlanır.
# Mounts a USB drive read-only. Drives in fstab or already mounted (e.g. a USB SSD) are skipped.
usb_add(){
  local dev="$1" uuid
  safe "$dev" && [ -b "/dev/$dev" ] || { echo "!! geçersiz aygıt / invalid device: $dev" >&2; return 1; }
  if findmnt -rn -S "/dev/$dev" >/dev/null; then echo "== /dev/$dev zaten bağlı, atlandı / already mounted, skipped"; return 0; fi
  uuid=$(blkid -s UUID -o value "/dev/$dev")
  if [ -n "$uuid" ] && grep -q "UUID=$uuid" /etc/fstab; then echo "== /dev/$dev fstab'da, atlandı / in fstab, skipped"; return 0; fi
  mkdir -p "$USB_DIR/$dev"
  mount -o ro,nosuid,nodev,noexec "/dev/$dev" "$USB_DIR/$dev" || { rmdir "$USB_DIR/$dev"; return 1; }
  echo "OK /dev/$dev -> $USB_DIR/$dev"
}

usb_remove(){
  safe "$1" || return 1
  if mountpoint -q "$USB_DIR/$1"; then umount -l "$USB_DIR/$1"; fi
  rmdir "$USB_DIR/$1" 2>/dev/null || true
}

usb_scan(){
  local avail items="" sep="" seen=" " base prefix current src size fits conf
  avail=$(df -B1 --output=avail "$DEST" | tail -1 | tr -dc '0-9')
  # MD5 bozulmayı yakalar, değiştirilmiş dosyayı yakalamaz; USB'den yalnızca content.conf'taki içerikler alınır.
  # The MD5 catches damage, not tampering; only content listed in content.conf is taken from a USB drive.
  conf=" $(awk '$1 !~ /^#/ && NF >= 2 {printf "%s ", $2}' "$CONF")"
  # Ters sıralı: aynı ZIM'in birden çok sürümü varsa en yenisi önce gelir / reverse order: newest version first
  while read -r base; do
    [[ "$base" =~ ^([A-Za-z0-9._-]+)_[0-9]{4}-[0-9]{2}[a-z]?\.zim$ ]] || continue
    prefix=${BASH_REMATCH[1]}
    case "$conf" in *" $prefix "*) ;; *) continue;; esac
    case "$seen" in *" $prefix "*) continue;; esac
    seen+="$prefix "
    current=$(cd "$DEST" && ls "$prefix"_[0-9][0-9][0-9][0-9]-[0-9][0-9]*.zim 2>/dev/null | tail -1)
    [ -n "$current" ] && [[ ! "$base" > "$current" ]] && continue
    src=$(find $USB_ROOTS -maxdepth 5 -type f -name "$base" -print -quit 2>/dev/null)
    size=$(stat -c %s "$src")
    fits=true; [ "$avail" -lt $((size + RESERVE_GB * GB)) ] && fits=false
    items+="$sep"$'\n'"  {\"id\":\"usb.$prefix\",\"kind\":\"usb\",\"file\":\"$base\",\"current\":\"$current\",\"latest\":\"$base\",\"size\":$size,\"fits\":$fits}"
    sep=","
  done < <(find $USB_ROOTS -maxdepth 5 -type f -name '*.zim' -printf '%f\n' 2>/dev/null | sort -ru)
  mkdir -p "$USB_DIR"
  write_json "$USB_JSON" <<EOF
{"scanned":"$(date -Is)","free":$avail,"reserve":$((RESERVE_GB * GB)),"items":[$items
]}
EOF
  echo "OK USB: $(grep -c '"id"' "$USB_JSON") içerik / items -> $USB_JSON"
}

# ZIM dosyasının son 16 baytı, öncesinin MD5 özetidir (openZIM biçimi; yeri başlıkta checksumPos).
# The last 16 bytes of a ZIM file are the MD5 of everything before them (openZIM format, checksumPos in the header).
zim_ok(){
  python3 - "$1" <<'EOF'
import hashlib, struct, sys
with open(sys.argv[1], "rb") as f:
    head = f.read(80)
    if len(head) < 80 or head[:4] != b"ZIM\x04":
        sys.exit(1)
    left = struct.unpack_from("<Q", head, 72)[0]
    f.seek(0)
    h = hashlib.md5()
    while left:
        b = f.read(min(left, 1 << 20))
        if not b:
            sys.exit(1)
        h.update(b)
        left -= len(b)
    sys.exit(0 if f.read(16) == h.digest() else 1)
EOF
}

usb_copy(){  # dosya ön-ek / file prefix
  local file="$1" prefix="$2" src avail old
  src=$(find $USB_ROOTS -maxdepth 5 -type f -name "$file" -print -quit 2>/dev/null)
  [ -n "$src" ] || { echo "!! $file USB'de bulunamadı / not found on the USB drive"; return 1; }
  avail=$(df -B1 --output=avail "$DEST" | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt $(( $(stat -c %s "$src") + RESERVE_GB * GB )) ]; then
    echo "!! $file için yer yok / not enough space"; return 1
  fi
  cp "$src" "$DEST/$file.part" || { echo "!! kopyalanamadı / copy failed"; rm -f "$DEST/$file.part"; return 1; }
  echo "   ZIM sağlaması doğrulanıyor / verifying ZIM checksum"
  zim_ok "$DEST/$file.part" || { echo "!! $file bozuk, silindi / corrupt, deleted"; rm -f "$DEST/$file.part"; return 1; }
  mv "$DEST/$file.part" "$DEST/$file"
  for old in "$DEST/$prefix"_[0-9][0-9][0-9][0-9]-[0-9][0-9]*.zim; do
    [ "$old" != "$DEST/$file" ] && [ -f "$old" ] && { echo "-- eski sürüm siliniyor / removing $old"; rm -f "$old"; }
  done
  iiab-make-kiwix-lib
}

results=""
status(){  # durum [ek alanlar] / state [extra fields]
  write_json "$STATUS" <<EOF
{"state":"$1","updated":"$(date -Is)","results":{$results}${2:+,$2}}
EOF
}

# Bir öğeyi indirir; ilerlemeyi .part dosyasının boyutundan izler.
# Downloads one item; progress is read from the size of its .part file.
run_item(){  # id satır kuyruk / id line queue
  local id="$1" line="$2" queue="$3" size part pid got conf=""
  size=$(field size "$line"); [ "$size" = null ] && size=0
  if [ "$(field kind "$line")" = usb ]; then
    part="$DEST/$(field file "$line").part"
    usb_copy "$(field file "$line")" "${id#usb.}" &
  elif [ "$(field kind "$line")" = map ]; then
    local name; name=$(field name "$line")
    part="$WEB/harita/data/$name.pmtiles.part"
    MAP_NAME="$name" WEB="$WEB" \
      MAP_BBOX="$(sed -nE 's/.*"bbox": *\[([^]]*)\].*/\1/p' "$MAP_META")" \
      MAP_MAXZOOM="$(sed -nE 's/.*"maxzoom": *([0-9]+).*/\1/p' "$MAP_META")" \
      "$REPO/scripts/download-map.sh" --update &
  else
    part="$DEST/$(field latest "$line").part"
    conf=$(mktemp)
    echo "$(field folder "$line") $id" > "$conf"
    DEST="$DEST" "$REPO/scripts/download-content.sh" "$conf" &
  fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    # .part bitince yeniden adlandırılır; o zaman son dosyanın boyutu okunur / after the rename read the final file
    got=$(stat -c %s "$part" "${part%.part}" 2>/dev/null | head -1)
    status running "\"current\":{\"id\":\"$id\",\"done\":${got:-0},\"size\":$size},\"queue\":[$queue]"
    sleep 3
  done
  wait "$pid"; local rc=$?
  [ -n "$conf" ] && rm -f "$conf"
  return $rc
}

apply(){
  if [ ${#ids[@]} -eq 0 ] && [ -f "$REQUEST" ]; then mapfile -t ids < "$REQUEST"; fi
  rm -f "$REQUEST"
  [ ${#ids[@]} -gt 0 ] || { echo "== güncellenecek bir şey seçilmedi / nothing selected"; return 0; }

  local i j id line queue failed=0 ok
  for i in "${!ids[@]}"; do
    id=${ids[$i]}
    safe "$id" || { echo "!! geçersiz ad / invalid id: $id" >&2; failed=1; continue; }
    queue=""; for j in "${ids[@]:i+1}"; do safe "$j" && queue+="${queue:+,}\"$j\""; done
    line=$(grep -shF "{\"id\":\"$id\"," "$UPDATES" "$USB_JSON" | head -1)
    if [ -z "$line" ] || [[ "$line" != *'"fits":true'* ]]; then
      echo "!! $id güncelleme listesinde yok ya da yer yok / not in the update list or no space" >&2; ok=false
    else
      echo ">> $id güncelleniyor / updating"
      if run_item "$id" "$line" "$queue"; then ok=true; else ok=false; fi
    fi
    [ "$ok" = true ] || failed=1
    results+="${results:+,}\"$id\":$ok"
  done
  if [ "$failed" = 0 ]; then status "done" "\"finished\":\"$(date -Is)\""; else status error "\"finished\":\"$(date -Is)\""; fi
  usb_scan
  FORCE=1 check
  return $failed
}

mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
if [ "$mode" = --usb ]; then
  case "$usbact" in
    --usb-add) usb_add "$usbdev" || exit 1;;
    --usb-remove) usb_remove "$usbdev";;
  esac
  flock -n 9 || { echo "== güncelleme sürüyor, sonunda taranacak / update running, rescans when done"; exit 0; }
  usb_scan
elif [ "$mode" = --check ]; then
  flock -n 9 || { echo "== başka bir güncelleme çalışıyor / another update is running"; exit 0; }
  check
else
  flock 9
  apply
fi
