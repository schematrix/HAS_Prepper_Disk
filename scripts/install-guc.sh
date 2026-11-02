#!/usr/bin/env bash
# Güç tasarrufu modunu kurar (kapalı başlar). Tekrar çalıştırmak güvenlidir.
# Installs the power saving mode (starts off). Safe to re-run.
#
# Kullanım / usage:  sudo ./scripts/install-guc.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }

install -d -m 755 /opt/has-guc
install -m 755 "$REPO/scripts/guc.sh" /opt/has-guc/
install -m 644 "$REPO/guc/has-guc.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable has-guc.service >/dev/null

cat <<EOT
Güç tasarrufu kuruldu / power saving installed.
Aç / on:      sudo ./scripts/guc.sh tasarruf
Kapat / off:  sudo ./scripts/guc.sh normal
Durum / status: ./scripts/guc.sh durum
EOT
