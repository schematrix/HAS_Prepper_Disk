#!/usr/bin/env bash
# config/content.conf içindeki ZIM dosyalarının en yeni sürümünü indirir ve Kiwix'e ekler.
# Downloads the newest version of each ZIM in config/content.conf and adds it to Kiwix.
# Yarıda kalırsa tekrar çalıştır, kaldığı yerden devam eder. / Re-run to resume.
#
# Kullanım / usage:  sudo ./scripts/download-content.sh [config-dosyası]
set -uo pipefail

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
CONF="${1:-$(cd "$(dirname "$0")/.." && pwd)/config/content.conf}"
DEST=/library/zims/content
BASE=https://download.kiwix.org/zim

mkdir -p "$DEST"
mountpoint -q /library || echo "Uyarı / warning: /library ayrı bir disk değil / is not a separate disk (SD kart dolabilir / SD card may fill up)"

failed=0
while read -r folder prefix _; do
  case "$folder" in ''|\#*) continue;; esac

  latest=$(curl -fsSL "$BASE/$folder/" | grep -oE "${prefix}_[0-9]{4}-[0-9]{2}[a-z]?\.zim" | sort -u | tail -1)
  if [ -z "$latest" ]; then echo "!! $prefix bulunamadı / not found in $BASE/$folder/"; failed=1; continue; fi

  if [ -f "$DEST/$latest" ]; then echo "== $latest zaten var / already present"; continue; fi

  echo ">> $latest indiriliyor / downloading"
  df -h /library | tail -1
  if wget -c --progress=dot:giga -O "$DEST/$latest.part" "$BASE/$folder/$latest" < /dev/null; then
    mv "$DEST/$latest.part" "$DEST/$latest"
    # Eski sürümleri sil / remove older versions of the same ZIM
    for old in "$DEST/${prefix}"_*.zim; do
      [ "$old" != "$DEST/$latest" ] && [ -f "$old" ] && { echo "-- eski sürüm siliniyor / removing $old"; rm -f "$old"; }
    done
  else
    echo "!! $latest indirilemedi / download failed (tekrar çalıştır / re-run to resume)"; failed=1
  fi
done < "$CONF"

echo ">> Kiwix kütüphanesi güncelleniyor / rebuilding Kiwix library"
if command -v iiab-make-kiwix-lib >/dev/null; then
  iiab-make-kiwix-lib
else
  echo "!! iiab-make-kiwix-lib yok / not found. Internet-in-a-Box kurulu mu? / is Internet-in-a-Box installed?"; failed=1
fi

exit $failed
