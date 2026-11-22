#!/usr/bin/env bash
set -euo pipefail
TARGET="nas-mgmt"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/schedule-merge" "$TARGET:/tmp/openvox-backup-schedule-merge"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'chmod +x /tmp/openvox-backup-schedule-merge; /tmp/openvox-backup-schedule-merge; rm -f /tmp/openvox-backup-schedule-merge'
