#!/usr/bin/env bash
# Hard precondition, read-only either way - mirrors the Ansible role's
# assert / spot's own equivalent check. Used as the `command` of an exec
# whose `unless` is always-false, so this always runs and its exit code
# is what determines success/failure (not gated by any drift check).
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

STATE=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "mdcmd status 2>/dev/null | grep -o 'mdState=[A-Z_]*'" || true)
if [ "$STATE" != "mdState=STARTED" ]; then
  echo "ERROR: Unraid array is not STARTED ($STATE) - /mnt/user is not mounted, deploying would write into the tmpfs root and be lost on reboot" >&2
  exit 1
fi
echo "array started"
