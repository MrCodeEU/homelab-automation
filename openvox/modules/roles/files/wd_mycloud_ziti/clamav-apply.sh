#!/usr/bin/env bash
# Rewrites the ziti-edge-tunnel block of clamAV's start.sh boot hook on
# wd-mycloud (the crontab is wiped at every reboot, so this is what starts
# the tunneler after one) - same block-replace as roles::wd_mycloud_proxy's
# own clamav-apply.sh, sent as a heredoc over `ssh ... bash -s`.
set -euo pipefail
TARGET="wd-mycloud-mgmt"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
HOOK=/mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh
TMP=/mnt/HD/HD_a2/ziti/.start.sh.tmp
sed \
  -e '/BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-ziti boot hook/,/END OPENVOX MANAGED BLOCK - wd-mycloud-ziti boot hook/d' \
  "$HOOK" > "$TMP"
{
  echo "# BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-ziti boot hook"
  echo "sh /mnt/HD/HD_a2/ziti/watchdog.sh &"
  echo "# END OPENVOX MANAGED BLOCK - wd-mycloud-ziti boot hook"
} >> "$TMP"
mv "$TMP" "$HOOK"
chmod +x "$HOOK"
echo "clamAV boot hook block written"
REMOTE
