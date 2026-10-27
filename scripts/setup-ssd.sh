#!/usr/bin/env bash
# SSD'yi /library klasörüne kalıcı olarak bağlar (Internet-in-a-Box içerikleri buraya yazar).
# Mounts the SSD permanently at /library (where Internet-in-a-Box stores content).
#
# Kullanım / usage:  sudo ./scripts/setup-ssd.sh /dev/nvme0n1
set -euo pipefail

DEV="${1:-}"
MP=/library

die(){ echo "HATA / ERROR: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "sudo ile çalıştır / run with sudo"
[ -n "$DEV" ] || { lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS; die "disk belirt / give a disk, e.g. /dev/nvme0n1"; }
[ -b "$DEV" ] || die "$DEV bulunamadı / not found"

ROOTDEV=$(findmnt -no SOURCE /)
case "$ROOTDEV" in "$DEV"*) die "$DEV sistem diski / is the system disk";; esac

if mountpoint -q "$MP" && [ "$(findmnt -no SOURCE "$MP")" = "$DEV" ]; then
  echo "$DEV zaten $MP altında bağlı / already mounted at $MP"; exit 0
fi

# Bağlıysa ayır / unmount if mounted elsewhere
for m in $(lsblk -nro MOUNTPOINTS "$DEV"); do umount "$m"; done

FSTYPE=$(lsblk -dno FSTYPE "$DEV")
if [ "$FSTYPE" != "ext4" ]; then
  echo
  echo "!!! $DEV ext4 değil ($FSTYPE). Formatlanacak ve ÜZERİNDEKİ HER ŞEY SİLİNECEK."
  echo "!!! $DEV is not ext4 ($FSTYPE). It will be formatted and EVERYTHING ON IT ERASED."
  read -rp "Devam için EVET yaz / type YES to continue: " ans
  [ "$ans" = "EVET" ] || [ "$ans" = "YES" ] || die "iptal / aborted"
  wipefs -a "$DEV"
  mkfs.ext4 -F -L prepperdisk "$DEV"
fi

UUID=$(blkid -s UUID -o value "$DEV")
[ -n "$UUID" ] || die "UUID okunamadı / could not read UUID"

if [ -d "$MP" ] && [ -n "$(ls -A "$MP" 2>/dev/null)" ] && ! mountpoint -q "$MP"; then
  echo "Uyarı / warning: $MP boş değil, içindekiler SSD bağlanınca gizlenecek / is not empty and will be hidden by the SSD"
fi

cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
# Bu disk ya da /library için eski satırları sil / remove old lines for this disk or /library
sed -i "/$UUID/d" /etc/fstab
sed -i '\#[[:space:]]/library[[:space:]]#d' /etc/fstab
echo "UUID=$UUID  $MP  ext4  defaults,noatime,nofail  0  2" >> /etc/fstab

mkdir -p "$MP"
systemctl daemon-reload
mount "$MP"
df -h "$MP"
echo "Tamam / done: $DEV -> $MP"
