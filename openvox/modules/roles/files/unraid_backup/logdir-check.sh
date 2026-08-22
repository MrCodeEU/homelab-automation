#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  '[ -d /mnt/user/appdata/homelab/backup/logs ]'
