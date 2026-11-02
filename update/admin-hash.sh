#!/bin/sh
# Yalnızca iiab-admin şifresinin özetini buton servisinin klasörüne koyar; servis /etc/shadow'u okuyamaz.
# Copies only the iiab-admin password hash into the button service's directory; the service can't read /etc/shadow.
set -eu
D=/run/has-update
[ -d "$D" ] || exit 0
getent shadow iiab-admin | cut -d: -f2 > "$D/admin.tmp"
chown --reference="$D" "$D/admin.tmp"
chmod 600 "$D/admin.tmp"
mv "$D/admin.tmp" "$D/admin"
