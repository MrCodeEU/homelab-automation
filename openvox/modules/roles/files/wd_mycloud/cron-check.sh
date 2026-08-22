#!/usr/bin/env bash
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'crontab -l 2>/dev/null | grep -qF /mnt/HD/HD_a2/tailscale/watchdog.sh'
