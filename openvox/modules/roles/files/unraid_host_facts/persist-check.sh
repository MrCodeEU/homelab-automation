#!/usr/bin/env bash
# Unraid rebuilds /root/.ssh from the flash at boot, so the live
# authorized_keys file alone would be lost on reboot - this pair mirrors
# it onto /boot/config/ssh/root (ported 1:1 from the Ansible role's own
# flash-persist step).
set -uo pipefail
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'cmp -s /root/.ssh/authorized_keys /boot/config/ssh/root/authorized_keys 2>/dev/null'
