#!/usr/bin/env bash
# Kutu sahibinin pano komutları / box owner's board commands
#
# Kullanım / usage:
#   sudo ./scripts/pano.sh duyuru "Su dağıtımı 14:00'te okul bahçesinde"   ana sayfaya duyuru / homepage announcement
#   sudo ./scripts/pano.sh duyuru-sil                                       duyuruyu kaldır / remove it
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
    sed -n '3,8p' "$0"; exit 2;;
esac
