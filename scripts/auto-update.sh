#!/usr/bin/env bash
# Otomatik güncelleme. Kendiliğinden hiçbir şey indirmez:
#   --check  internet varsa yeni sürümleri bulur, ana sayfanın okuduğu updates.json'a yazar
#   --apply  ana sayfada onaylanan içerikleri indirir, ilerlemeyi update-status.json'a yazar
# Automatic updates. Never downloads anything on its own:
#   --check  if online, finds newer versions and writes them to updates.json (read by the homepage)
#   --apply  downloads the items approved on the homepage, progress goes to update-status.json
# İndirmeyi download-content.sh ve download-map.sh yapar (SHA-256, yer kontrolü, eski sürümü silme).
# The actual downloads are done by download-content.sh and download-map.sh.
#
# Kullanım / usage:
#   sudo ./scripts/auto-update.sh --check [--force]   --force olmadan 6 saatte birden sık bakmaz / at most every 6 h without --force
#   sudo ./scripts/auto-update.sh --apply [id ...]    id yoksa ana sayfanın istek dosyasını okur / without ids reads the homepage request
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
BUILDS_URL=https://build-metadata.protomaps.dev/builds.json
GB=$((1024 * 1024 * 1024))

mode=""; FORCE=0; ids=()
for a in "$@"; do
  case "$a" in
    --check|--apply) mode=$a;;
    --force) FORCE=1;;
    -*) echo "bilinmeyen seçenek / unknown option: $a" >&2; exit 2;;
    *) ids+=("$a");;
  esac
done
[ -n "$mode" ] || { echo "kullanım / usage: $0 --check [--force] | --apply [id ...]" >&2; exit 2; }
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
    local name have build bytes mapavail
    name=$(sed -nE 's/.*"name": *"([^"]*)".*/\1/p' "$MAP_META")
    have=$(sed -nE 's/.*"build": *"([0-9]{8})".*/\1/p' "$MAP_META")
    bytes=$(sed -nE 's/.*"bytes": *([0-9]+).*/\1/p' "$MAP_META")
    build=$(curl -fsSL -m 60 "$BUILDS_URL" | grep -oE '"key":"[0-9]{8}\.pmtiles"' | grep -oE '[0-9]{8}' | sort | tail -1)
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
  if [ "$(field kind "$line")" = map ]; then
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
  [ -f "$UPDATES" ] || { echo "!! önce / run first: $0 --check" >&2; return 1; }

  local i j id line queue failed=0 ok
  for i in "${!ids[@]}"; do
    id=${ids[$i]}
    safe "$id" || { echo "!! geçersiz ad / invalid id: $id" >&2; failed=1; continue; }
    queue=""; for j in "${ids[@]:i+1}"; do safe "$j" && queue+="${queue:+,}\"$j\""; done
    line=$(grep -F "{\"id\":\"$id\"," "$UPDATES")
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
  FORCE=1 check
  return $failed
}

mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
if [ "$mode" = --check ]; then
  flock -n 9 || { echo "== başka bir güncelleme çalışıyor / another update is running"; exit 0; }
  check
else
  flock 9
  apply
fi
