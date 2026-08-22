#!/usr/bin/env bash
# Rewrites clamAV's start.sh boot hook block on wd-mycloud, stripping any
# older-generation managed block (Ansible's or spot's own marker names)
# before appending the current one - same pattern as
# roles::wd_mycloud_proxy's own clamav-apply.sh, sent as a heredoc over
# `ssh ... bash -s` to avoid any quoting risk.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
HOOK=/mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh
TMP=/mnt/HD/HD_a2/node_exporter/.start.sh.tmp
sed \
  -e '/BEGIN ANSIBLE MANAGED BLOCK - wd-mycloud-node-exporter boot hook/,/END ANSIBLE MANAGED BLOCK - wd-mycloud-node-exporter boot hook/d' \
  -e '/BEGIN SPOT MANAGED BLOCK - wd-mycloud-node-exporter boot hook/,/END SPOT MANAGED BLOCK - wd-mycloud-node-exporter boot hook/d' \
  -e '/BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-node-exporter boot hook/,/END OPENVOX MANAGED BLOCK - wd-mycloud-node-exporter boot hook/d' \
  "$HOOK" > "$TMP"
{
  echo "# BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-node-exporter boot hook"
  echo "sh /mnt/HD/HD_a2/node_exporter/watchdog.sh &"
  echo "# END OPENVOX MANAGED BLOCK - wd-mycloud-node-exporter boot hook"
} >> "$TMP"
mv "$TMP" "$HOOK"
chmod +x "$HOOK"
echo "clamAV boot hook block written"
REMOTE
