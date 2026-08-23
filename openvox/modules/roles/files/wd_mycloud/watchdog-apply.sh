#!/usr/bin/env bash
# Writes the reference watchdog.sh content (deployed alongside this
# script) onto wd-mycloud via scp - avoids any shell-quoting risk from
# embedding the script body in a command string.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/watchdog-content.sh" "$TARGET:/mnt/HD/HD_a2/tailscale/watchdog.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'chmod 0755 /mnt/HD/HD_a2/tailscale/watchdog.sh'
echo "watchdog.sh written"
