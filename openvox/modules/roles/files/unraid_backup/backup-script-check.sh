#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
US_DIR="/boot/config/plugins/user.scripts/scripts/nas-backup"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "cat $US_DIR/script 2>/dev/null" \
  | cmp -s - "$DIR/backup-content.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "[ \"\$(cat $US_DIR/name 2>/dev/null)\" = nas-backup ]"
