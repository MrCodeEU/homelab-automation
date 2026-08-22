#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/schedule-merge.py" "$TARGET:/tmp/openvox-schedule-merge.py"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'python3 /tmp/openvox-schedule-merge.py --check'
