#!/usr/bin/env bash
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "grep -qF 'sh /mnt/HD/HD_a2/tailscale/watchdog.sh &' /mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh"
