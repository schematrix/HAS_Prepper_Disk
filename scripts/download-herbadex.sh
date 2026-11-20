#!/usr/bin/env bash
# Herbadex (herbadex.com) çevrimdışı sürümünü indirir, SHA-256 ile doğrular ve
# /library/www/html/herbadex altına atomik olarak kurar.
# Downloads the newest offline Herbadex release, verifies SHA-256, and installs it
# atomically under /library/www/html/herbadex (served by IIAB nginx at /herbadex/).
#
# Yarıda kalırsa tekrar çalıştır, kaldığı yerden devam eder. / Re-run to resume.
#
# Kullanım / usage:
#   sudo ./scripts/download-herbadex.sh [--variant maxi|nopic] [--force] [config-dosyası]
# Ortam / environment:
#   DEST=/library/www/html/herbadex  RESERVE_GB=5  HERBADEX_MANIFEST_URL=...
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$REPO/config/herbadex.conf"
DEST="${DEST:-/library/www/html/herbadex}"
RESERVE_GB="${RESERVE_GB:-5}"
UA="${HERBADEX_USER_AGENT:-HAS-PrepperDisk/1.0}"

ENABLED="true"
VARIANT="maxi"
MANIFEST_URL="${HERBADEX_MANIFEST_URL:-https://herbadex.com/offline/manifest.json}"
ENV_MANIFEST_URL="${HERBADEX_MANIFEST_URL:-}"
CLI_VARIANT=""
FORCE=0

usage() {
  cat <<'EOF'
Kullanım / usage:
  sudo ./scripts/download-herbadex.sh [--variant maxi|nopic] [--force] [config-dosyası]

Seçenekler / options:
  --variant maxi|nopic   Resimli (maxi) veya resimsiz (nopic) sürüm / with or without images
  --force                Aynı sürüm kurulu olsa bile yeniden indir / re-download even if current
  -h, --help             Bu yardımı göster / show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)
      [ $# -ge 2 ] || { echo "!! --variant değer gerektirir / requires a value (maxi|nopic)" >&2; exit 1; }
      CLI_VARIANT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "!! Bilinmeyen seçenek / unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      CONF="$1"
      shift
      ;;
  esac
done

[ "$EUID" -eq 0 ] || [ "${HERBADEX_ALLOW_NON_ROOT:-0}" = "1" ] || {
  echo "sudo ile çalıştır / run with sudo" >&2
  exit 1
}

# Yapılandırma dosyasını güvenli biçimde oku / safely parse key=value config
if [ -f "$CONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val#\"}"
    val="${val%\"}"
    case "$key" in
      HERBADEX_ENABLED) ENABLED="$val" ;;
      HERBADEX_VARIANT) VARIANT="$val" ;;
      HERBADEX_MANIFEST_URL) [ -z "$ENV_MANIFEST_URL" ] && MANIFEST_URL="$val" ;;
    esac
  done < "$CONF"
fi

[ -n "$CLI_VARIANT" ] && VARIANT="$CLI_VARIANT"

case "$ENABLED" in
  false|FALSE|0|no|NO)
    if [ -z "$CLI_VARIANT" ] && [ "$FORCE" -eq 0 ]; then
      echo "== Herbadex devre dışı / disabled ($CONF)"
      exit 0
    fi
    ;;
esac

case "$VARIANT" in
  maxi|nopic) ;;
  *)
    echo "!! Geçersiz varyant / invalid variant: $VARIANT (beklenen / expected: maxi | nopic)" >&2
    exit 1
    ;;
esac

for cmd in curl wget python3 tar xz sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "!! $cmd bulunamadı / not found" >&2
    exit 1
  fi
done

PARENT="$(dirname "$DEST")"
mkdir -p "$PARENT"
if [ "$DEST" = "/library/www/html/herbadex" ]; then
  mountpoint -q /library || echo "Uyarı / warning: /library ayrı bir disk değil / is not a separate disk (SD kart dolabilir / SD card may fill up)"
fi

TMP_MANIFEST="$(mktemp)"
STAGE=""
cleanup() {
  rm -f "$TMP_MANIFEST"
  [ -n "$STAGE" ] && rm -rf "$STAGE"
}
trap cleanup EXIT

echo ">> Herbadex kataloğu alınıyor / fetching Herbadex manifest ($MANIFEST_URL)"
if ! curl -fsSL -A "$UA" -m 60 "$MANIFEST_URL" -o "$TMP_MANIFEST"; then
  echo "!! Herbadex manifest indirilemedi / could not fetch manifest ($MANIFEST_URL)" >&2
  exit 1
fi

parsed="$(python3 - "$TMP_MANIFEST" "$VARIANT" <<'PY'
import json, re, sys

manifest_path, variant = sys.argv[1], sys.argv[2]
with open(manifest_path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

version = str(data.get('version', '')).strip()
entry = (data.get('variants') or {}).get(variant)
if not version or not isinstance(entry, dict):
    sys.exit(2)

filename = str(entry.get('filename', '')).strip()
url = str(entry.get('url', '')).strip()
sha256 = str(entry.get('sha256', '')).strip().lower()
size_bytes = int(entry.get('sizeBytes', 0))
uncompressed = int(entry.get('uncompressedBytes', 0))
herbs = int((data.get('counts') or {}).get('herbs', 0))

if not re.fullmatch(r'[A-Za-z0-9._-]+\.tar\.xz', filename):
    sys.exit(3)
if not re.match(r'^https?://', url):
    sys.exit(4)
if not re.fullmatch(r'[0-9a-f]{64}', sha256):
    sys.exit(5)

print('\t'.join([version, filename, url, sha256, str(size_bytes), str(uncompressed), str(herbs)]))
PY
)"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$parsed" ]; then
  echo "!! Herbadex manifest geçersiz veya '$VARIANT' varyantı yok / invalid manifest or missing '$VARIANT' variant" >&2
  exit 1
fi

IFS=$'\t' read -r version filename url expected_sha size_bytes uncompressed_bytes herb_count <<< "$parsed"

# Kurulu sürümle karşılaştır / compare with installed release
if [ "$FORCE" -eq 0 ] && [ -f "$DEST/meta.json" ]; then
  installed="$(python3 - "$DEST/meta.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    d = json.load(fh)
print(f"{d.get('version', '')}\t{d.get('variant', '')}")
PY
)"
  IFS=$'\t' read -r inst_ver inst_var <<< "$installed"
  if [ "$inst_ver" = "$version" ] && [ "$inst_var" = "$VARIANT" ]; then
    echo "== Herbadex $version ($VARIANT, $herb_count bitki / herbs) zaten güncel / already up to date"
    exit 0
  fi
fi

PART="$PARENT/.herbadex-${version}-${VARIANT}.part"
have=0
[ -f "$PART" ] && have="$(stat -c %s "$PART")"
avail="$(df -B1 --output=avail "$PARENT" | tail -1 | tr -dc '0-9')"
remaining=$((size_bytes > have ? size_bytes - have : 0))
needed=$((remaining + uncompressed_bytes + RESERVE_GB * 1024 * 1024 * 1024))
if [ "$avail" -lt "$needed" ]; then
  echo "!! Herbadex için yer yok / not enough space: gerekli / needed $(((remaining + uncompressed_bytes) / 1024 / 1024)) MB + ${RESERVE_GB} GB pay / headroom, boş / free $((avail / 1024 / 1024)) MB" >&2
  exit 1
fi

size_mb="$(( (size_bytes + 524288) / 1048576 ))"
disk_mb="$(( (uncompressed_bytes + 524288) / 1048576 ))"
echo ">> Herbadex $version ($VARIANT, $herb_count bitki / herbs) indiriliyor / downloading (~${size_mb} MB arşiv / archive, ~${disk_mb} MB disk)"
df -h "$PARENT" | tail -1
if ! wget -c --user-agent="$UA" --progress=dot:giga -O "$PART" "$url" < /dev/null; then
  echo "!! $filename indirilemedi / download failed (tekrar çalıştır / re-run to resume)" >&2
  exit 1
fi

echo "   sha256 hesaplanıyor / verifying checksum"
actual_sha="$(sha256sum "$PART" | awk '{print $1}')"
if [ "$actual_sha" != "$expected_sha" ]; then
  echo "!! $filename sha256 uyuşmuyor, bozuk dosya silindi / checksum mismatch, corrupt file deleted (beklenen / expected $expected_sha, bulunan / got $actual_sha)" >&2
  rm -f "$PART"
  exit 1
fi
echo "   sha256 doğru / checksum OK"

STAGE="$PARENT/.herbadex-stage.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
echo ">> Arşiv açılıyor / extracting $filename"
if ! tar -xJf "$PART" -C "$STAGE"; then
  echo "!! Arşiv açılamadı / failed to extract $filename" >&2
  exit 1
fi

if [ ! -f "$STAGE/index.html" ] || [ ! -f "$STAGE/meta.json" ]; then
  echo "!! Beklenen dosyalar eksik (index.html / meta.json) / expected archive files missing" >&2
  exit 1
fi

chmod -R a+rX "$STAGE"

OLD="$PARENT/.herbadex-old.$$"
rm -rf "$OLD"
if [ -d "$DEST" ]; then
  mv "$DEST" "$OLD"
fi
if ! mv "$STAGE" "$DEST"; then
  [ -d "$OLD" ] && mv "$OLD" "$DEST"
  echo "!! Yeni sürüm etkinleştirilemedi / failed to activate new release" >&2
  exit 1
fi
STAGE=""
rm -rf "$OLD" "$PART"

# Eski yarım indirmeleri temizle / remove stale partial downloads from earlier versions
for stale in "$PARENT"/.herbadex-*.part; do
  [ -f "$stale" ] && rm -f "$stale"
done

echo "OK Herbadex $version ($VARIANT) kuruldu / installed: http://box.lan/herbadex/"
echo "   Lisans / license: CC BY-NC-ND 4.0 (yalnızca ticari olmayan kişisel kullanım / non-commercial personal use only)"
