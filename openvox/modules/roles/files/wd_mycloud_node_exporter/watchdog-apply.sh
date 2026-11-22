#!/usr/bin/env bash
# Writes the reference watchdog.sh content (deployed alongside this
# script) onto wd-mycloud via scp - avoids any shell-quoting risk from
# embedding the script body in a command string.
set -euo pipefail
TARGET="wd-mycloud-mgmt"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/watchdog-content.sh" "$TARGET:/mnt/HD/HD_a2/node_exporter/watchdog.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'chmod 0755 /mnt/HD/HD_a2/node_exporter/watchdog.sh'
# A node_exporter still on another listen address than the new watchdog's
# (its Tailscale IP until Phase 5, now 127.0.0.1 for wd-mycloud-exporter
# over Ziti) is restarted by it. [n]: must not match this command's shell.
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'if pgrep -f "[n]ode_exporter --web.listen-address" >/dev/null && ! pgrep -f "[n]ode_exporter --web.listen-address=127.0.0.1:9100" >/dev/null; then
     pkill -f "[n]ode_exporter --web.listen-address"; sleep 2; sh /mnt/HD/HD_a2/node_exporter/watchdog.sh; echo "node_exporter restarted on 127.0.0.1:9100"
   fi'
echo "watchdog.sh written"
