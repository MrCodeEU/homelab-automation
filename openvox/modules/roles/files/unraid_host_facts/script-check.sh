#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGED="${DIR}/../openvox-unraid-host-facts-staging/homelab-facts.py"
EXPECTED_HASH=$(sha256sum "$STAGED" | awk '{print $1}')

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "
  set -eu
  dest=/mnt/user/appdata/homelab/bin/homelab-facts
  [ -f \"\$dest\" ]
  [ \"\$(sha256sum \"\$dest\" | awk '{print \$1}')\" = '${EXPECTED_HASH}' ]
  [ -L /usr/local/bin/homelab-facts ]
  [ \"\$(readlink /usr/local/bin/homelab-facts)\" = \"\$dest\" ]
"
