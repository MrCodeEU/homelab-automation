#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'mkdir -p /mnt/user/appdata/homelab/backup/logs && chmod 755 /mnt/user/appdata/homelab/backup/logs'
echo "backup log directory ensured"
