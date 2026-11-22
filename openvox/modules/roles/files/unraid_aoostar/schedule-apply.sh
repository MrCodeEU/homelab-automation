#!/usr/bin/env bash
set -euo pipefail
TARGET="nas-mgmt"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scp -q -o StrictHostKeyChecking=accept-new "$DIR/schedule-merge" "$TARGET:/tmp/openvox-schedule-merge-aoostar"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" 'chmod +x /tmp/openvox-schedule-merge-aoostar; /tmp/openvox-schedule-merge-aoostar; rm -f /tmp/openvox-schedule-merge-aoostar'
