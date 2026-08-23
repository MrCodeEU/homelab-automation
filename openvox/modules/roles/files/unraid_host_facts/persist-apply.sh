#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" '
  set -euo pipefail
  mkdir -p /boot/config/ssh/root
  chown root:root /boot/config/ssh/root
  chmod 700 /boot/config/ssh/root
  cp /root/.ssh/authorized_keys /boot/config/ssh/root/authorized_keys
  chown root:root /boot/config/ssh/root/authorized_keys
  chmod 600 /boot/config/ssh/root/authorized_keys
  echo "persisted authorized_keys to flash"
'
