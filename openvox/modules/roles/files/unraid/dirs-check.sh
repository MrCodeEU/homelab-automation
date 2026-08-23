#!/usr/bin/env bash
# Exits 0 (no work needed) if all 3 array-side directories already exist
# with the expected mode.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
BASE=/mnt/user/appdata/homelab
check() {
  dir="$1"; mode="$2"
  [ -d "$dir" ] || exit 1
  [ "$(stat -c '%a' "$dir")" = "$mode" ] || exit 1
}
check "$BASE" 755
check "$BASE/bin" 755
check "$BASE/.docker" 700
REMOTE
