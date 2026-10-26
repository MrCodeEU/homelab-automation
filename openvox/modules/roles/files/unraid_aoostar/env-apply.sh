#!/usr/bin/env bash
# Writes controller.env on nas (mode 600) from the eyaml-held secrets.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/env-render.sh"
render_env | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'umask 077; mkdir -p /mnt/user/appdata/aoostar; cat > /mnt/user/appdata/aoostar/controller.env.new && chmod 600 /mnt/user/appdata/aoostar/controller.env.new && mv /mnt/user/appdata/aoostar/controller.env.new /mnt/user/appdata/aoostar/controller.env'
echo "aoostar controller.env written"
