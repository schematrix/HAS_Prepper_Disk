#!/usr/bin/env bash
# Kutu sahibinin pano komutları / box owner's board commands
#
# Kullanım / usage:
#   sudo ./scripts/pano.sh duyuru "Su dağıtımı 14:00'te okul bahçesinde"   ana sayfaya duyuru / homepage announcement
#   sudo ./scripts/pano.sh duyuru-sil                                       duyuruyu kaldır / remove it
#   sudo ./scripts/pano.sh kayitlar [arama]                                 kayıtları numarasıyla listele / list entries with their ids
#   sudo ./scripts/pano.sh sil <numara>                                     tek kaydı sil / delete one entry
#   sudo ./scripts/pano.sh temizle                                          tüm Güvendeyim kayıtlarını sil / wipe all entries
#   sudo ./scripts/pano.sh kapat | ac                                       Güvendeyim panosunu kapat / aç  (disable / enable)
set -euo pipefail

DUYURU=/library/www/html/home/duyuru.json
DATA=/var/lib/has-pano/guvendeyim.json

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo"

case "${1:-}" in
  duyuru)
    [ -n "${2:-}" ] || die "duyuru metni gerekli / announcement text required"
    python3 -c 'import datetime, json, sys
json.dump({"metin": sys.argv[1][:500], "zaman": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)' "$2" "$DUYURU.tmp"
    chmod 644 "$DUYURU.tmp" && mv "$DUYURU.tmp" "$DUYURU"
    echo "Duyuru yayında / announcement published: http://box.lan/home";;
  duyuru-sil)
    rm -f "$DUYURU"; echo "Duyuru kaldırıldı / announcement removed";;
  kayitlar)
    [ -f "$DATA" ] || { echo "Kayıt yok / no entries"; exit 0; }
    python3 -c 'import json, sys
q = sys.argv[2].casefold()
for e in json.load(open(sys.argv[1], encoding="utf-8")):
    line = "  ".join((e["id"], e["zaman"][:16], e["durum"], e["ad"], e["yer"], e["mesaj"]))
    if q in line.casefold():
        print(line)' "$DATA" "${2:-}";;
  sil)
    [ -n "${2:-}" ] || die "kayıt numarası gerekli, bkz. kayitlar / entry id required, see kayitlar"
    [ -f "$DATA" ] || die "kayıt yok / no entries"
    active=$(systemctl is-active has-pano-api || true)
    systemctl stop has-pano-api
    rc=0
    python3 -c 'import json, os, sys
entries = json.load(open(sys.argv[1], encoding="utf-8"))
kept = [e for e in entries if e["id"] != sys.argv[2]]
if len(kept) == len(entries):
    sys.exit(1)
with open(sys.argv[1] + ".tmp", "w", encoding="utf-8") as f:
    json.dump(kept, f, ensure_ascii=False)
os.replace(sys.argv[1] + ".tmp", sys.argv[1])' "$DATA" "$2" || rc=$?
    [ "$active" = active ] && systemctl start has-pano-api
    [ "$rc" -eq 0 ] || die "$2 numaralı kayıt yok / no such entry"
    echo "Kayıt silindi / entry deleted";;
  temizle)
    read -rp "Tüm Güvendeyim kayıtları silinecek. Devam için EVET yaz / type YES to wipe all entries: " a
    [ "$a" = EVET ] || [ "$a" = YES ] || die "iptal / aborted"
    active=$(systemctl is-active has-pano-api || true)
    systemctl stop has-pano-api
    rm -f "$DATA" "$DATA.tmp"
    [ "$active" = active ] && systemctl start has-pano-api
    echo "Tüm kayıtlar silindi / all entries wiped";;
  kapat)
    systemctl disable --now has-pano-api >/dev/null; echo "Güvendeyim panosu kapatıldı / board disabled";;
  ac)
    systemctl enable --now has-pano-api >/dev/null; echo "Güvendeyim panosu açıldı / board enabled";;
  *)
    sed -n '3,10p' "$0"; exit 2;;
esac
