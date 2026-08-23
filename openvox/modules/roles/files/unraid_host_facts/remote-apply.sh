#!/usr/bin/env bash
# Runs ON nas via ssh - pushed as a real file, same reasoning as
# remote-check.sh.
set -euo pipefail
DEST="/mnt/user/appdata/homelab/bin/homelab-facts"
CANDIDATE="/tmp/openvox-homelab-facts-candidate.py"

mkdir -p "$(dirname "$DEST")"
mv "$CANDIDATE" "$DEST"
chown root:root "$DEST"
chmod 755 "$DEST"
ln -sf "$DEST" /usr/local/bin/homelab-facts
echo "installed $DEST"
