#!/usr/bin/env bash
# Disk ve güç sağlığı denetimini kurar. Tekrar çalıştırmak güvenlidir.
# Installs the disk and power health check. Safe to re-run.
#
# Kullanım / usage:  sudo ./scripts/install-disk-health.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }

command -v smartctl >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools >/dev/null \
  || echo "Uyarı / warning: smartmontools kurulamadı, SMART denetimi atlanacak / not installed, SMART check skipped"

for u in has-disk-health.service has-disk-health.timer; do
  sed "s#@REPO@#$REPO#g" "$REPO/saglik/$u" > "/etc/systemd/system/$u"
  chmod 644 "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now has-disk-health.timer >/dev/null
systemctl start has-disk-health.service
echo "Disk sağlığı denetimi kuruldu / disk health check installed"
