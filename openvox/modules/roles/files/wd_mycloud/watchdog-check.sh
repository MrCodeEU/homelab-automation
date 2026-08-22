#!/usr/bin/env bash
# Exits 0 (no work needed) if wd-mycloud's watchdog.sh already matches the
# reference content deployed alongside this script.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -o BatchMode=yes "$TARGET" 'cat /mnt/HD/HD_a2/tailscale/watchdog.sh 2>/dev/null' \
  | cmp -s - "$DIR/watchdog-content.sh"
