#!/usr/bin/env bash
# Exit 0 when controller.env on nas equals the rendered content and is mode 600.
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/env-render.sh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'f=/mnt/user/appdata/aoostar/controller.env; [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] && cat "$f"' \
  | cmp -s - <(render_env)
