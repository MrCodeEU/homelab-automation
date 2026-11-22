#!/usr/bin/env bash
set -euo pipefail
TARGET="nas-mgmt"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  '[ -d /mnt/user/appdata/homelab/backup/logs ]'
