#!/usr/bin/env bash
# Exits 0 (no work needed) if nas's live TCP sysctls already match. /etc is
# tmpfs on Unraid; bootstrap-content.sh sets the same value at array start.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

[ "$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'sysctl -n net.ipv4.tcp_notsent_lowat')" = 131072 ]
