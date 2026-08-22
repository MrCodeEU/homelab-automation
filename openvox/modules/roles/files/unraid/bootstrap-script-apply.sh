#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
US_DIR="/boot/config/plugins/user.scripts/scripts/homelab-compose-up"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "mkdir -p $US_DIR"
scp -q -o StrictHostKeyChecking=accept-new "$DIR/bootstrap-content.sh" "$TARGET:$US_DIR/script"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "
  chmod 755 $US_DIR/script
  echo homelab-compose-up > $US_DIR/name
  chmod 644 $US_DIR/name
  printf '%s\n' 'Managed by OpenVox (roles::unraid_proxy, proxy-exec from nuc). Restores managed compose projects and helper binaries after the tmpfs root is rebuilt.' > $US_DIR/description
  chmod 644 $US_DIR/description
"
echo "bootstrap script + User Scripts metadata installed"
