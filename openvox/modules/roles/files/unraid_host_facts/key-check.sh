#!/usr/bin/env bash
# $OPENVOX_HEALTHREPORT_AUTH_ENTRY is set by the calling exec resource's
# own `environment => [...]`. Base64-encoded across the ssh boundary
# (rather than interpolated into a quoted remote command string) since
# the entry itself contains embedded double quotes
# (restrict,from="...",command="...") - avoids a repeat of the nested-
# quoting fragility this migration already hit once (see
# roles::wd_mycloud_proxy's own header comment).
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_B64=$(printf '%s' "${OPENVOX_HEALTHREPORT_AUTH_ENTRY}" | base64 -w0)

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'cat > /tmp/openvox-homelab-facts-key-check.sh' < "$DIR/remote-key-check.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "bash /tmp/openvox-homelab-facts-key-check.sh \"\$(echo ${ENTRY_B64} | base64 -d)\"; RC=\$?; rm -f /tmp/openvox-homelab-facts-key-check.sh; exit \$RC"
