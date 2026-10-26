#!/usr/bin/env bash
# Exits 0 (no work needed) if every installed AOOSTAR file matches the repo.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/mnt/user/appdata/aoostar"
US_DIR="/boot/config/plugins/user.scripts/scripts"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

same() { "${SSH[@]}" "$TARGET" "cat '$2' 2>/dev/null" | cmp -s - "$1"; }

same "$DIR/aoostar-ctl.sh" "$APP_DIR/aoostar-ctl.sh"
same "$DIR/aoostar-controller.sh" "$APP_DIR/aoostar-controller.sh"
same "$DIR/user-script-start.sh" "$US_DIR/aoostar-display/script"
same "$DIR/user-script-stop.sh" "$US_DIR/aoostar-display-stop/script"
"${SSH[@]}" "$TARGET" "[ \"\$(cat $US_DIR/aoostar-display/name 2>/dev/null)\" = aoostar-display ] && [ \"\$(cat $US_DIR/aoostar-display-stop/name 2>/dev/null)\" = aoostar-display-stop ]"
