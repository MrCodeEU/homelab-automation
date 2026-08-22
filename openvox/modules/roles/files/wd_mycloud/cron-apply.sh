#!/usr/bin/env bash
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
ssh -o BatchMode=yes "$TARGET" \
  "(crontab -l 2>/dev/null; echo '*/5 * * * * sh /mnt/HD/HD_a2/tailscale/watchdog.sh') | crontab -"
echo "watchdog cron entry added"
