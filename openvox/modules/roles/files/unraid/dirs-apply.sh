#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s <<'REMOTE'
set -e
BASE=/mnt/user/appdata/homelab
ensure() {
  dir="$1"; mode="$2"
  mkdir -p "$dir"
  chmod "$mode" "$dir"
}
# Executables and registry credentials live on the array because
# /usr/local/bin and /root are tmpfs; bootstrap.sh re-links both into
# place at array start.
ensure "$BASE" 755
ensure "$BASE/bin" 755
ensure "$BASE/.docker" 700
echo "array-side directories ensured"
REMOTE
