#!/usr/bin/env bash
# Exits 0 (no work needed) if nuc has no backup-remote key yet (matches
# Ansible's own `when: ... | length > 0` skip - nothing to install), or if
# nas already has the matching key + rclone-ugreen.conf content. The key
# lives on nuc's own local disk (real disk, not tmpfs) - since this whole
# class runs ON nuc as the proxy host, no cross-host propagation dance is
# needed at all (unlike spot's controller-in-the-middle model, which had
# to pull-then-push through a separate machine).
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_KEY="/opt/backup-remote/ssh/id_ed25519"
REMOTE_DIR="/mnt/user/appdata/homelab/backup-remote"

[ -f "$LOCAL_KEY" ] || exit 0

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "cat $REMOTE_DIR/ssh/id_ed25519 2>/dev/null" | cmp -s - "$LOCAL_KEY"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "cat $REMOTE_DIR/rclone-ugreen.conf 2>/dev/null" | cmp -s - "$DIR/rclone-ugreen-content.conf"
