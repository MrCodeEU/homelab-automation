#!/usr/bin/env bash
set -euo pipefail
TARGET="wd-mycloud-mgmt"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "grep -qF 'sh /mnt/HD/HD_a2/ziti/watchdog.sh &' /mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh"
