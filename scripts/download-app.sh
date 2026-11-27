#!/usr/bin/env bash
# Kiwix'in Android uygulamasını kutuya indirir; telefonlar onu internetsiz, ana sayfadan kurar.
# Downloads the Kiwix Android app so phones can install it from the homepage without internet.
#
# Kullanım / usage:  sudo ./scripts/download-app.sh
set -euo pipefail

API=https://api.github.com/repos/kiwix/kiwix-android/releases/latest
# Güncel telefonlar arm64-v8a (~70 MB), eskiler armeabi-v7a (~64 MB); hepsi bir arada paket 236 MB.
# Current phones are arm64-v8a, older ones armeabi-v7a; the all-in-one package is 236 MB.
ABIS="arm64-v8a armeabi-v7a"
DIR=/library/www/html/telefon

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo"
[ -d /library/www/html ] || die "/library/www/html yok. Önce / install first:  sudo ./install.sh"

# GitHub her dosyanın SHA-256 özetini verir; Kiwix sunucusundaki .md5 dosyaları güncel değil.
# GitHub publishes a SHA-256 for every file; the .md5 files on Kiwix's own server are stale.
RELEASE=$(curl -fsSL "$API") || die "GitHub'a ulaşılamadı / cannot reach GitHub"
LIST=$(printf '%s' "$RELEASE" | python3 -c '
import json, sys
r = json.load(sys.stdin)
for abi in sys.argv[1].split():
    for a in r["assets"]:
        if a["name"].endswith(f"-{abi}-standalone.apk") and (a.get("digest") or "").startswith("sha256:"):
            print(abi, a["name"], a["digest"][7:], a["browser_download_url"])
' "$ABIS")
[ -n "$LIST" ] || die "sürümde uygulama dosyası yok / no app files in the release"

install -d -m 755 "$DIR"
keep=()
while read -r _ name sha url; do
  keep+=("$name")
  if [ -f "$DIR/$name" ]; then
    echo "Güncel / up to date: $name"
    continue
  fi
  echo "İndiriliyor / downloading $name"
  curl -fL --retry 3 -C - -o "$DIR/$name.part" "$url" || true
  if ! echo "$sha  $DIR/$name.part" | sha256sum -c --status 2>/dev/null; then
    rm -f "$DIR/$name.part"
    die "SHA-256 tutmadı, dosya silindi / checksum mismatch, file removed: $name"
  fi
  mv "$DIR/$name.part" "$DIR/$name"
  chmod 644 "$DIR/$name"
done <<< "$LIST"

for f in "$DIR"/*.apk; do
  [ -e "$f" ] || continue
  printf '%s\n' "${keep[@]}" | grep -qxF "$(basename "$f")" || rm -f "$f"
done

python3 -c '
import json, os, sys
print(json.dumps([{"abi": abi, "file": name, "size": os.path.getsize(os.path.join(sys.argv[1], name))}
                  for abi, name, *_ in (line.split() for line in sys.stdin if line.strip())]))
' "$DIR" <<< "$LIST" > "$DIR/app.json.tmp"
chmod 644 "$DIR/app.json.tmp"
mv "$DIR/app.json.tmp" "$DIR/app.json"
echo "Telefonlar buradan kurar / phones install it from: http://box.lan/home/telefon.html"
