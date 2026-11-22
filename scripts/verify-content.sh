#!/usr/bin/env bash
# Tamamlanmış ZIM dosyalarını yerleşik sağlama toplamıyla çevrimdışı doğrular.
# Verifies complete ZIM archives offline using their embedded checksum.
set -uo pipefail
shopt -s nullglob

usage(){
  printf 'Kullanım / usage: %s [ZIM-dosyası-veya-klasör / ZIM-file-or-directory]\n' "$0"
  printf 'Varsayılan klasör / default directory: /library/zims/content\n'
}

if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
case "${1:-}" in -h|--help) usage; exit 0;; esac

target="${1:-/library/zims/content}"
[[ "$target" = /* ]] || target="./$target"
if [ -d "$target" ] && [ -r "$target" ] && [ -x "$target" ]; then
  archives=("$target"/*.zim)
elif [[ -f "$target" && "$target" = *.zim ]]; then
  archives=("$target")
else
  printf '!! ZIM dosyası veya okunabilir klasör gerekli / expected a ZIM file or readable directory: %s\n' "$target" >&2
  exit 2
fi

if ! command -v zimcheck >/dev/null; then
  echo '!! zimcheck bulunamadı / not found. Kurulum / install: sudo apt install zim-tools' >&2
  exit 2
fi

checked=0
failed=0
for archive in "${archives[@]}"; do
  [ -f "$archive" ] || continue
  checked=$((checked + 1))
  printf '>> Doğrulanıyor / checking: %s\n' "$archive"
  if ! zimcheck --checksum "$archive"; then
    printf '!! Doğrulanamadı / verification failed: %s\n' "$archive" >&2
    failed=$((failed + 1))
  fi
done

if [ "$checked" -eq 0 ]; then
  printf '!! Tamamlanmış ZIM bulunamadı / no complete ZIM files found: %s\n' "$target" >&2
  exit 2
fi

printf '%s ZIM kontrol edildi / checked, %s hata / failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]
