#!/usr/bin/env bash
# Installs the break-glass keys on wd-mycloud and hardens its sshd. The
# root filesystem (including /home/root and /etc/ssh/sshd_config) is a RAM
# disk rebuilt at every boot, so both are re-applied at every boot from a
# managed block in clamAV's start.sh (the same boot hook the tailscale
# watchdog uses), as well as now.
#
# sshd hardening:
#   - AllowUsers sshd root  (the firmware ships only `sshd`, which is uid 0
#     / home /home/root, i.e. root; adding `root` lets the normal name be
#     used too - both resolve to the same account and key file)
#   - PasswordAuthentication no, PermitEmptyPasswords no
# Daily access is Tailscale SSH, served by tailscaled (not sshd), so it is
# unaffected by AllowUsers and stays available as a recovery path even if
# this edit were wrong. The config is validated with `sshd -t` before the
# running sshd is reloaded, so a bad edit can never take sshd down.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'mkdir -p /mnt/HD/HD_a2/breakglass && chmod 0700 /mnt/HD/HD_a2/breakglass'
scp -q -o StrictHostKeyChecking=accept-new "$DIR/breakglass-authorized_keys" "$TARGET:/mnt/HD/HD_a2/breakglass/authorized_keys"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
SRC=/mnt/HD/HD_a2/breakglass/authorized_keys
chmod 0600 "$SRC"
mkdir -p /home/root/.ssh
chmod 0700 /home/root/.ssh
cp "$SRC" /home/root/.ssh/authorized_keys
chmod 0600 /home/root/.ssh/authorized_keys

# Harden the live sshd config (validate before reloading).
CONF=/etc/ssh/sshd_config
TMP=/mnt/HD/HD_a2/breakglass/.sshd_config.tmp
sed -e '/^[[:space:]]*AllowUsers/d' \
    -e '/^[[:space:]]*PasswordAuthentication/d' \
    -e '/^[[:space:]]*PermitEmptyPasswords/d' \
    "$CONF" > "$TMP"
printf 'AllowUsers sshd root\nPasswordAuthentication no\nPermitEmptyPasswords no\n' >> "$TMP"
if /usr/sbin/sshd -t -f "$TMP"; then
  cp "$TMP" "$CONF"
  PID=$(cat /run/sshd.pid 2>/dev/null || cat /var/run/sshd.pid 2>/dev/null || true)
  [ -n "$PID" ] && kill -HUP "$PID" 2>/dev/null || true
else
  echo "sshd -t rejected the hardened config; left sshd_config unchanged" >&2
  rm -f "$TMP"; exit 1
fi
rm -f "$TMP"

HOOK=/mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh
TMP=/mnt/HD/HD_a2/breakglass/.start.sh.tmp
sed -e '/BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook/,/END OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook/d' \
  "$HOOK" > "$TMP"
{
  echo "# BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook"
  echo "mkdir -p /home/root/.ssh && chmod 0700 /home/root/.ssh && cp /mnt/HD/HD_a2/breakglass/authorized_keys /home/root/.ssh/authorized_keys && chmod 0600 /home/root/.ssh/authorized_keys"
  echo "sed -e '/^[[:space:]]*AllowUsers/d' -e '/^[[:space:]]*PasswordAuthentication/d' -e '/^[[:space:]]*PermitEmptyPasswords/d' /etc/ssh/sshd_config > /tmp/.sshd_bg && printf 'AllowUsers sshd root\\nPasswordAuthentication no\\nPermitEmptyPasswords no\\n' >> /tmp/.sshd_bg && /usr/sbin/sshd -t -f /tmp/.sshd_bg && cp /tmp/.sshd_bg /etc/ssh/sshd_config && { kill -HUP \"\$(cat /run/sshd.pid 2>/dev/null || cat /var/run/sshd.pid 2>/dev/null)\" 2>/dev/null || true; }; rm -f /tmp/.sshd_bg"
  echo "# END OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook"
} >> "$TMP"
mv "$TMP" "$HOOK"
chmod +x "$HOOK"
echo "break-glass keys installed, sshd hardened, boot hook block written"
REMOTE
