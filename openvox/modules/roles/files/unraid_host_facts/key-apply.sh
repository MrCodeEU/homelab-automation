#!/usr/bin/env bash
# See key-check.sh for why the entry crosses the ssh boundary base64-encoded.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_B64=$(printf '%s' "${OPENVOX_HEALTHREPORT_AUTH_ENTRY}" | base64 -w0)

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'cat > /tmp/openvox-homelab-facts-key-apply.sh' < "$DIR/remote-key-apply.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "bash /tmp/openvox-homelab-facts-key-apply.sh \"\$(echo ${ENTRY_B64} | base64 -d)\"; RC=\$?; rm -f /tmp/openvox-homelab-facts-key-apply.sh; exit \$RC"
