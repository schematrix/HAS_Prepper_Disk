#!/usr/bin/env bash
# Çevrimdışı vektör harita: Protomaps planet build'inden bölge kesiti (PMTiles) + harita sayfası + yazı tipleri.
# Offline vector map: region extract (PMTiles) from the Protomaps planet build + map page + fonts.
# Her şey /library/www/html/harita/ altına yazılır; Internet-in-a-Box'ın nginx'i düz dosya olarak sunar
# (Range isteklerini kendisi karşılar, ek ayar yok): http://box.lan/harita/
# Everything is written under /library/www/html/harita/; the IIAB nginx serves it as plain files
# (it handles Range requests itself, no extra config): http://box.lan/harita/
#
# Neden / why: IIAB'ın harita indirmesi bazı ülkelerde (ör. Türkiye) engelli (README'deki contabostorage notu).
# Bu betik yalnızca build.protomaps.com, github.com ve cdn.jsdelivr.net'e gider. / This script only talks to
# build.protomaps.com, github.com and cdn.jsdelivr.net.
#
# Kullanım / usage:  sudo ./scripts/download-map.sh [--update] [--force]
#   (seçenek yok)  harita yoksa indirir, varsa durumu bildirip çıkar / download if missing, otherwise report and exit
#   --update       daha yeni planet build'i varsa yeniden keser / re-extract when a newer build exists
#   --force        her durumda yeniden keser / always re-extract
# Ayarlar (ortam değişkeni / env): MAP_NAME (turkiye), MAP_BBOX (lonW,latS,lonE,latN), MAP_MAXZOOM (15),
#   MAP_BUILD (YYYYMMDD; boş = en yeni / empty = latest), WEB (/library/www/html), RESERVE_GB (5)
# Örnek / example (Almanya / Germany):  sudo MAP_NAME=almanya MAP_BBOX=5.8,47.2,15.1,55.1 ./scripts/download-map.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="${WEB:-/library/www/html}"
HARITA="$WEB/harita"
MAPS="$HARITA/data"
LIB="$HARITA/lib"
MAP_NAME="${MAP_NAME:-turkiye}"
MAP_BBOX="${MAP_BBOX:-25.5,35.7,45.0,42.2}"   # Türkiye + kıyı/ada payı; ölçülen kesit 1,7 GB (2026-10-31 build, z15)
MAP_MAXZOOM="${MAP_MAXZOOM:-15}"
MAP_BUILD="${MAP_BUILD:-}"
RESERVE_GB="${RESERVE_GB:-5}"
PMTILES_VERSION=1.31.2
# go-pmtiles yayını checksums dosyası vermiyor; sürüm sabitlenir, tarball sha256'ları burada tutulur (2026-11-01).
# The go-pmtiles release has no checksums file; version is pinned and tarball sha256 values are kept here.
PMTILES_SHA_x86_64=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f
PMTILES_SHA_arm64=f8bd47e7ea866863489cad588fbaf2f31f42e5821f7a03f009b3769f05801cb1
BUILDS_URL=https://build-metadata.protomaps.dev/builds.json
BUILD_BASE=https://build.protomaps.com
ASSETS_URL=https://github.com/protomaps/basemaps-assets/archive/refs/heads/main.tar.gz
JSD=https://cdn.jsdelivr.net/npm
LOCK=/run/lock/harita-indir.lock

UPDATE=0; FORCE=0
for a in "$@"; do case "$a" in --update) UPDATE=1;; --force) FORCE=1;; *) echo "bilinmeyen seçenek / unknown option: $a" >&2; exit 2;; esac; done
[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
[ -d "$WEB" ] || { echo "$WEB yok. Önce Internet-in-a-Box'ı kur / install Internet-in-a-Box first" >&2; exit 1; }
for c in curl tar sha256sum flock; do command -v "$c" >/dev/null || { echo "$c gerekli / required" >&2; exit 1; }; done
exec 9>"$LOCK"; flock -n 9 || { echo "başka bir harita indirmesi çalışıyor / another map download is running ($LOCK)"; exit 0; }
mkdir -p "$MAPS" "$LIB"
failed=0

# --- sayfa + kütüphaneler / page + libraries -----------------------------------------------------------
# Sürümler ve sha256'lar sabit; güncellerken ikisini birlikte değiştir. / Versions and hashes are pinned.
fetch_lib() {  # dosya url sha256
  local f="$1" url="$2" sum="$3"
  if [ -f "$LIB/$f" ] && echo "$sum  $LIB/$f" | sha256sum -c --quiet 2>/dev/null; then return 0; fi
  if curl -fsSL -m 300 -o "$LIB/$f.part" "$url" && echo "$sum  $LIB/$f.part" | sha256sum -c --quiet; then
    mv "$LIB/$f.part" "$LIB/$f"
  else
    echo "!! $f indirilemedi veya sha256 uyuşmuyor / download failed or sha256 mismatch" >&2
    rm -f "$LIB/$f.part"; failed=1
  fi
}
cp "$DIR/www/harita/index.html" "$HARITA/index.html"
cp "$DIR"/www/harita/lib/LICENSE-*.txt "$LIB/"
fetch_lib maplibre-gl.js  "$JSD/maplibre-gl@5.24.0/dist/maplibre-gl.js"        45a9b07a9189ce56054c620a947ccf41e291e58c95e9b61533b740aaa65ee5cb
fetch_lib maplibre-gl.css "$JSD/maplibre-gl@5.24.0/dist/maplibre-gl.css"       ab1e70d59ec40465bae7e7030da2f3ccf28133fd502e62bd598eefbadfd7a732
fetch_lib pmtiles.js      "$JSD/pmtiles@4.5.0/dist/pmtiles.js"                 caf981bc46f6327ee7e65d5dc964d89d38a69f60edca2bd4c5c890c21b554c6c
fetch_lib basemaps.js     "$JSD/@protomaps/basemaps@5.7.2/dist/basemaps.js"    551864f01da1bfe3005e99987197f22f56d0c35f9a10fa1727a889e2434af16d
chmod -R a+rX "$HARITA"

# --- pmtiles CLI (GitHub release, sürüm + sha256 sabit) ------------------------------------------------
if ! command -v pmtiles >/dev/null; then
  case "$(uname -m)" in
    x86_64)        arch=x86_64; sum=$PMTILES_SHA_x86_64;;
    aarch64|arm64) arch=arm64;  sum=$PMTILES_SHA_arm64;;
    *) echo "!! desteklenmeyen mimari / unsupported arch: $(uname -m)" >&2; exit 1;;
  esac
  tgz="go-pmtiles_${PMTILES_VERSION}_Linux_${arch}.tar.gz"
  tmp=$(mktemp -d)
  echo "[$(date -Is)] pmtiles CLI indiriliyor / downloading: $tgz"
  if ! curl -fsSL -m 300 -o "$tmp/$tgz" "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/$tgz"; then
    echo "!! pmtiles indirilemedi / download failed" >&2; rm -rf "$tmp"; exit 1
  fi
  if ! echo "$sum  $tmp/$tgz" | sha256sum -c --quiet; then
    echo "!! pmtiles sha256 uyuşmuyor, kurulmadı / checksum mismatch, not installed" >&2; rm -rf "$tmp"; exit 1
  fi
  tar xzf "$tmp/$tgz" -C "$tmp" pmtiles && install -m 0755 "$tmp/pmtiles" /usr/local/bin/pmtiles
  rm -rf "$tmp"
fi
echo "pmtiles: $(pmtiles version 2>&1 | head -1)"

# --- en yeni planet build / latest planet build --------------------------------------------------------
if [ -z "$MAP_BUILD" ]; then
  MAP_BUILD=$(curl -fsSL -m 60 "$BUILDS_URL" | grep -oE '"key":"[0-9]{8}\.pmtiles"' | grep -oE '[0-9]{8}' | sort | tail -1)
  [ -n "$MAP_BUILD" ] || { echo "!! build listesi alınamadı / cannot read $BUILDS_URL" >&2; exit 1; }
fi
OUT="$MAPS/$MAP_NAME.pmtiles"; META="$MAPS/map.json"
have=""; [ -f "$META" ] && have=$(grep -oE '"build": *"[0-9]{8}"' "$META" | grep -oE '[0-9]{8}')

extract=1
if [ -f "$OUT" ] && [ "$FORCE" = 0 ]; then
  if [ "$UPDATE" = 0 ]; then
    echo "== $OUT var (yapı/build ${have:-?}, en yeni/latest $MAP_BUILD); yenilemek için / to refresh: --update"; extract=0
  elif [ -n "$have" ] && [ "$have" -ge "$MAP_BUILD" ]; then
    echo "== $OUT zaten en yeni yapı / already latest build ($have)"; extract=0
  fi
fi

if [ "$extract" = 1 ]; then
  avail=$(df -B1 --output=avail "$MAPS" | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt $(( (RESERVE_GB + 3) * 1024*1024*1024 )) ]; then
    echo "!! $MAPS için yer yok / not enough space (boş/free $((avail/1024/1024)) MB; kesit/extract ~2 GB + $RESERVE_GB GB pay/headroom)" >&2; exit 1
  fi
  src="$BUILD_BASE/$MAP_BUILD.pmtiles"
  echo "[$(date -Is)] >> $MAP_NAME kesiliyor / extracting: build $MAP_BUILD, bbox $MAP_BBOX, maxzoom $MAP_MAXZOOM (Türkiye ~1,7 GB, 2-10 dk)"
  rm -f "$OUT.part"
  # İlerleme çubuğu \r ile aynı satırı yeniler; log'a yüzlerce KB çöp yazmasın diye süzülür.
  # The progress bar rewrites one line with \r; filter it so logs do not fill with noise.
  pmtiles extract "$src" "$OUT.part" --bbox="$MAP_BBOX" --maxzoom="$MAP_MAXZOOM" --download-threads=4 < /dev/null 2>&1 \
    | tr '\r' '\n' | grep -vE '^ *fetching chunks|^[[:space:]]*$' | sed 's/^/   /'
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ] && pmtiles verify "$OUT.part" >/dev/null 2>&1; then
    mv "$OUT.part" "$OUT"; chmod 0644 "$OUT"
    bytes=$(stat -c %s "$OUT")
    printf '{"name":"%s","build":"%s","bbox":[%s],"maxzoom":%s,"bytes":%s,"updated":"%s","source":"%s"}\n' \
      "$MAP_NAME" "$MAP_BUILD" "$MAP_BBOX" "$MAP_MAXZOOM" "$bytes" "$(date -Is)" "$src" > "$META"
    chmod 0644 "$META"
    echo "[$(date -Is)] OK $OUT ($((bytes/1024/1024)) MB)"
    pmtiles show "$OUT" 2>/dev/null | grep -E 'tile entries|zoom|bounds' | sed 's/^/   /'
  else
    echo "!! kesit başarısız veya doğrulanamadı, .part silindi / extract failed or did not verify" >&2
    rm -f "$OUT.part"; failed=1
  fi
fi

# --- yazı tipleri + sprite'lar (basemaps-assets, ~6 MB) / fonts + sprites ------------------------------
if [ ! -f "$MAPS/assets/sprites/v4/light.json" ] || [ ! -f "$MAPS/assets/fonts/Noto Sans Regular/0-255.pbf" ]; then
  tmp=$(mktemp -d)
  echo "[$(date -Is)] >> yazı tipi/sprite paketi indiriliyor / downloading fonts and sprites"
  if curl -fsSL -m 300 -o "$tmp/assets.tgz" "$ASSETS_URL" \
     && mkdir -p "$MAPS/assets" \
     && tar xzf "$tmp/assets.tgz" -C "$MAPS/assets" --strip-components=1 --wildcards \
          'basemaps-assets-main/fonts/Noto Sans Regular/*' 'basemaps-assets-main/fonts/Noto Sans Medium/*' \
          'basemaps-assets-main/fonts/Noto Sans Italic/*' 'basemaps-assets-main/fonts/OFL.txt' \
          'basemaps-assets-main/sprites/v4/*' 'basemaps-assets-main/README.md'; then
    chmod -R a+rX "$MAPS/assets"
    echo "   OK fonts: $(find "$MAPS/assets/fonts" -name '*.pbf' | wc -l) pbf, sprites: $(ls "$MAPS/assets/sprites/v4" | wc -l) dosya/files"
  else
    echo "!! paket indirilemedi; etiketler ve simgeler görünmez (tekrar çalıştır) / assets failed, labels and icons will be missing" >&2
    failed=1
  fi
  rm -rf "$tmp"
fi

chmod -R a+rX "$HARITA"
echo "[$(date -Is)] bitti / done (failed=$failed)"; df -h "$MAPS" | tail -1
[ -f "$OUT" ] && echo "Harita / map: http://box.lan/harita/"
exit $failed
