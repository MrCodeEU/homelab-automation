#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/schedule-merge.py" "$TARGET:/tmp/openvox-backup-schedule-merge.py"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'python3 /tmp/openvox-backup-schedule-merge.py; rm -f /tmp/openvox-backup-schedule-merge.py'
