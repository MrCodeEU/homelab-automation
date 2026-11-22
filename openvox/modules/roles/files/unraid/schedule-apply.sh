#!/usr/bin/env bash
set -euo pipefail
TARGET="nas-mgmt"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q -o StrictHostKeyChecking=accept-new "$DIR/schedule-merge" "$TARGET:/tmp/openvox-schedule-merge"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'chmod +x /tmp/openvox-schedule-merge; /tmp/openvox-schedule-merge; rm -f /tmp/openvox-schedule-merge'
