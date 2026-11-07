#!/usr/bin/env bash
# config/content.conf içindeki ZIM dosyalarının en yeni sürümünü indirir ve Kiwix'e ekler.
# Downloads the newest version of each ZIM in config/content.conf and adds it to Kiwix.
# Yarıda kalırsa tekrar çalıştır, kaldığı yerden devam eder. / Re-run to resume.
#
# Sürüm çözme: Kiwix OPDS kataloğu (library.kiwix.org) tek istekte tüm ZIM'lerin adını, boyutunu ve
# adresini verir; klasör listesi yalnızca katalog erişilemezse kullanılır.
# Version lookup: the Kiwix OPDS catalog returns every ZIM's name, size and URL in one request;
# the directory listing is only a fallback when the catalog is unreachable.
# Her dosya indirildikten sonra Kiwix'in yayımladığı .sha256 ile doğrulanır, bozuksa silinir.
# Each download is verified against the .sha256 Kiwix publishes next to it; a corrupt file is deleted.
#
# Kullanım / usage:  sudo ./scripts/download-content.sh [config-dosyası]
# Ortam / environment:  DEST=/library/zims/content  RESERVE_GB=5 (boş bırakılacak pay / headroom to keep free)
set -uo pipefail

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
CONF="${1:-$(cd "$(dirname "$0")/.." && pwd)/config/content.conf}"
DEST="${DEST:-/library/zims/content}"
RESERVE_GB="${RESERVE_GB:-5}"
BASE=https://download.kiwix.org/zim
CATALOG_URL="${CATALOG_URL:-https://library.kiwix.org/catalog/v2/entries?count=-1}"
CAT=$(mktemp)
trap 'rm -f "$CAT"' EXIT

mkdir -p "$DEST"
mountpoint -q /library || echo "Uyarı / warning: /library ayrı bir disk değil / is not a separate disk (SD kart dolabilir / SD card may fill up)"

echo ">> Kiwix kataloğu alınıyor / fetching Kiwix catalog"
if ! curl -fsSL -m 300 "$CATALOG_URL" -o "$CAT"; then
  echo "!! Katalog alınamadı, klasör listesine düşülüyor / catalog unreachable, falling back to directory listings"
  CAT=""
fi

failed=0
while read -r folder prefix _; do
  case "$folder" in ''|\#*) continue;; esac

  url=""; size=""
  if [ -n "$CAT" ]; then
    # Katalog satırı / catalog line:  href="https://.../zim/<folder>/<prefix>_YYYY-MM.zim.meta4" ... length="<bytes>"
    entry=$(grep -oE "href=\"https://[^\"]*/${prefix}_[0-9]{4}-[0-9]{2}[a-z]?\.zim\.meta4\"[^>]*length=\"[0-9]+\"" "$CAT" | sort -u | tail -1)
    if [ -n "$entry" ]; then
      url=$(sed -E 's/^href="([^"]*)\.meta4".*/\1/' <<<"$entry")
      size=$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$entry")
      case "$url" in */zim/"$folder"/*) ;; *) echo "   not / note: $prefix katalogda '$folder' klasöründe değil / is not under '$folder' in the catalog ($url)";; esac
    fi
  else
    latest=$(curl -fsSL "$BASE/$folder/" | grep -oE "${prefix}_[0-9]{4}-[0-9]{2}[a-z]?\.zim" | sort -u | tail -1)
    [ -n "$latest" ] && url="$BASE/$folder/$latest"
  fi
  if [ -z "$url" ]; then echo "!! $prefix bulunamadı / not found in the Kiwix catalog (ad değişmiş veya kaldırılmış olabilir / name may have changed or been retired)"; failed=1; continue; fi
  latest=$(basename "$url")

  if [ -f "$DEST/$latest" ]; then echo "== $latest zaten var / already present"; continue; fi

  # Yer kontrolü / free-space check: kalan boyut + pay / remaining bytes + headroom
  [ -z "$size" ] && size=$(curl -sIL -m 30 "$url" | grep -i '^content-length:' | tail -1 | tr -dc '0-9')
  have=0; [ -f "$DEST/$latest.part" ] && have=$(stat -c %s "$DEST/$latest.part")
  avail=$(df -B1 --output=avail "$DEST" | tail -1 | tr -dc '0-9')
  if [ -n "$size" ] && [ "$avail" -lt $((size - have + RESERVE_GB * 1024 * 1024 * 1024)) ]; then
    echo "!! $latest için yer yok / not enough space: gerekli / needed $(((size - have) / 1024 / 1024)) MB + ${RESERVE_GB} GB pay / headroom, boş / free $((avail / 1024 / 1024)) MB"
    failed=1; continue
  fi

  sizetxt="boyut bilinmiyor / size unknown"; [ -n "$size" ] && sizetxt="$((size / 1024 / 1024)) MB"
  echo ">> $latest indiriliyor / downloading ($sizetxt)"
  df -h "$DEST" | tail -1
  if ! wget -c --progress=dot:giga -O "$DEST/$latest.part" "$url" < /dev/null; then
    echo "!! $latest indirilemedi / download failed (tekrar çalıştır / re-run to resume)"; failed=1; continue
  fi

  # SHA-256 doğrulama / verification
  expected=$(curl -fsSL -m 60 "$url.sha256" 2>/dev/null | awk '{print $1}')
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "   Uyarı / warning: $latest için .sha256 yayımlanmamış, doğrulanmadan kabul edildi / no .sha256 published, accepted unverified"
  else
    echo "   sha256 hesaplanıyor / verifying checksum"
    actual=$(sha256sum "$DEST/$latest.part" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
      echo "!! $latest sha256 uyuşmuyor, bozuk dosya silindi / checksum mismatch, corrupt file deleted (beklenen / expected $expected, bulunan / got $actual)"
      rm -f "$DEST/$latest.part"; failed=1; continue
    fi
    echo "   sha256 doğru / checksum OK"
  fi

  mv "$DEST/$latest.part" "$DEST/$latest"
  echo "OK $latest tamamlandı / done"
  # Eski sürümleri sil / remove older versions of the same ZIM
  for old in "$DEST/${prefix}"_[0-9][0-9][0-9][0-9]-[0-9][0-9]*.zim; do
    [ "$old" != "$DEST/$latest" ] && [ -f "$old" ] && { echo "-- eski sürüm siliniyor / removing $old"; rm -f "$old"; }
  done
done < "$CONF"

echo ">> Kiwix kütüphanesi güncelleniyor / rebuilding Kiwix library"
if command -v iiab-make-kiwix-lib >/dev/null; then
  iiab-make-kiwix-lib
else
  echo "!! iiab-make-kiwix-lib yok / not found. Internet-in-a-Box kurulu mu? / is Internet-in-a-Box installed?"; failed=1
fi

exit $failed
