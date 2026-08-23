#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGED="${DIR}/../openvox-unraid-host-facts-staging/homelab-facts.py"

scp -q -o StrictHostKeyChecking=accept-new "$STAGED" "$TARGET:/tmp/openvox-homelab-facts-candidate.py"
scp -q -o StrictHostKeyChecking=accept-new "$DIR/remote-apply.sh" "$TARGET:/tmp/openvox-homelab-facts-remote-apply.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'bash /tmp/openvox-homelab-facts-remote-apply.sh; RC=$?; rm -f /tmp/openvox-homelab-facts-remote-apply.sh; exit $RC'
