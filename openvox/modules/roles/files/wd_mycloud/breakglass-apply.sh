#!/usr/bin/env bash
# Installs the break-glass keys on wd-mycloud. Its root filesystem
# (including /home/root) is a RAM disk rebuilt at every boot, so the keys
# are kept on the data disk and copied into root's ~/.ssh twice: now, and
# at every boot from a managed block in clamAV's start.sh (the same boot
# hook the tailscale watchdog uses). Password login is left alone here;
# switch it off only after a real key login was tested.
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

HOOK=/mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh
TMP=/mnt/HD/HD_a2/breakglass/.start.sh.tmp
sed -e '/BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook/,/END OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook/d' \
  "$HOOK" > "$TMP"
{
  echo "# BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook"
  echo "mkdir -p /home/root/.ssh && chmod 0700 /home/root/.ssh && cp /mnt/HD/HD_a2/breakglass/authorized_keys /home/root/.ssh/authorized_keys && chmod 0600 /home/root/.ssh/authorized_keys"
  echo "# END OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook"
} >> "$TMP"
mv "$TMP" "$HOOK"
chmod +x "$HOOK"
echo "break-glass keys installed, boot hook block written"
REMOTE
