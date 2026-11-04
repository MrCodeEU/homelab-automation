#!/usr/bin/env bash
# Exits 0 (no work needed) if wd-mycloud already has the break-glass keys
# (breakglass-authorized_keys, written next to this script by
# roles::wd_mycloud_proxy) on its data disk and in root's live
# ~/.ssh/authorized_keys, and the clamAV boot hook restores them.
# Read-only: safe as an exec guard under --noop.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$DIR/breakglass-authorized_keys"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'cat /mnt/HD/HD_a2/breakglass/authorized_keys 2>/dev/null' \
  | cmp -s - "$KEYS"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'cat /home/root/.ssh/authorized_keys 2>/dev/null' \
  | cmp -s - "$KEYS"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "grep -qF 'BEGIN OPENVOX MANAGED BLOCK - wd-mycloud-breakglass boot hook' /mnt/HD/HD_a2/Nas_Prog/clamAV/start.sh"
