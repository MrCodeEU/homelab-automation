#!/usr/bin/env bash
# Sets nas's live TCP sysctls (see bootstrap-content.sh step 0 for why).
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'sysctl -w net.ipv4.tcp_notsent_lowat=131072'
