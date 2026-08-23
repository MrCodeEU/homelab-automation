#!/usr/bin/env bash
# Exits 0 (no work needed) if the User Scripts entry's script content and
# name file already match the expected values.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
US_DIR="/boot/config/plugins/user.scripts/scripts/homelab-compose-up"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "cat $US_DIR/script 2>/dev/null" | cmp -s - "$DIR/bootstrap-content.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "[ \"\$(cat $US_DIR/name 2>/dev/null)\" = homelab-compose-up ]"
