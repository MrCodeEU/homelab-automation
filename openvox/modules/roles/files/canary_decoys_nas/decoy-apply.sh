#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/mnt/user/Fotos/Passwords-Backup.docx"
OLD_DEST="/mnt/user/Fotos/Passwords-Backup.pdf"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/Passwords-Backup.docx" "$TARGET:$DEST"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "chmod 644 '$DEST'; rm -f '$OLD_DEST'"
echo "canary decoy placed at $DEST"
