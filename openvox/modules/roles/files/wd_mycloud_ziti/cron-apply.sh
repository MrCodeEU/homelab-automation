#!/usr/bin/env bash
set -euo pipefail
TARGET="wd-mycloud-mgmt"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "(crontab -l 2>/dev/null; echo '*/5 * * * * sh /mnt/HD/HD_a2/ziti/watchdog.sh') | crontab -"
echo "watchdog cron entry added"
