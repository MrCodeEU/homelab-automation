#!/usr/bin/env bash
# Exits 0 (no work needed) if the array-side file's content already
# matches the vendored copy exactly - same cmp-based guard as
# roles::unraid_proxy's own bootstrap-script-check.sh.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/mnt/user/Fotos/Passwords-Backup.docx"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "cat '$DEST' 2>/dev/null" | cmp -s - "$DIR/Passwords-Backup.docx"
