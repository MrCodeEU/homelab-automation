#!/usr/bin/env bash
# Installs the backup-remote SSH key + ugreen rclone config on nas,
# reading the key straight from nuc's own local disk - never printed,
# never echoed, transferred via scp only (real SFTP content transfer).
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_KEY="/opt/backup-remote/ssh/id_ed25519"
REMOTE_DIR="/mnt/user/appdata/homelab/backup-remote"

if [ ! -f "$LOCAL_KEY" ]; then
  echo "no backup-remote key on nuc yet - nothing to install (matches Ansible's when-skip)"
  exit 0
fi

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "mkdir -p $REMOTE_DIR/ssh && chmod 700 $REMOTE_DIR/ssh"
scp -q -o StrictHostKeyChecking=accept-new "$LOCAL_KEY" "$TARGET:$REMOTE_DIR/ssh/id_ed25519"
scp -q -o StrictHostKeyChecking=accept-new "$DIR/rclone-ugreen-content.conf" "$TARGET:$REMOTE_DIR/rclone-ugreen.conf"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "chmod 600 $REMOTE_DIR/ssh/id_ed25519 $REMOTE_DIR/rclone-ugreen.conf"
echo "backup-remote key + rclone-ugreen.conf installed"
