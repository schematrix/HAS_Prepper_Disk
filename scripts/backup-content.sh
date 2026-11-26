#!/usr/bin/env bash
# Tamamlanmış ZIM arşivlerini bağlı bir diske yedekler.
# Backs up completed ZIM archives to a mounted disk.
set -uo pipefail
shopt -s nullglob

source_dir=/library/zims/content
backup_dir=./HAS-zims
options=(--times --modify-window=1 --no-whole-file --partial-dir=.has-partial
  --itemize-changes --human-readable --stats)

usage(){ printf 'Kullanım / usage: %s [--dry-run] /media/usb\n' "$0"; }
die(){ printf 'HATA / ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0;;
  --dry-run) options+=(--dry-run); shift;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
command -v rsync >/dev/null || die 'rsync bulunamadı / not found. Kurulum / install: sudo apt install rsync'

archives=()
for archive in "$source_dir"/*.zim; do
  if [ -f "$archive" ] && [ ! -L "$archive" ]; then archives+=("$archive"); fi
done
[ "${#archives[@]}" -gt 0 ] || die "Tamamlanmış ZIM bulunamadı / no complete ZIM files found: $source_dir"

cd -- "$1" || die "Hedefe girilemedi / cannot open destination: $1"
mountpoint -q . || die "Hedef bağlı bir disk olmalı / destination must be a mount point: $1"
destination_device=$(stat -c %d -- .) || die 'Hedef disk okunamadı / cannot inspect destination disk'
source_device=$(stat -c %d -- "$source_dir") || die 'Kaynak disk okunamadı / cannot inspect source disk'
root_device=$(stat -c %d -- /) || die 'Sistem diski okunamadı / cannot inspect system disk'
if [ "$destination_device" = "$source_device" ] || [ "$destination_device" = "$root_device" ]; then
  die 'Ayrı bir yedek diski seç / choose a destination separate from the content and system disks'
fi

if [ -L "$backup_dir" ]; then
  die 'Yedek klasörü sembolik bağ olamaz / backup directory must not be a symlink'
fi
if [ -e "$backup_dir" ]; then
  [ -d "$backup_dir" ] && [ "$(stat -c %d -- "$backup_dir")" = "$destination_device" ] ||
    die 'Yedek klasörü hedef diskte olmalı / backup directory must be on the destination disk'
fi

exec rsync "${options[@]}" -- "${archives[@]}" "$backup_dir/"
