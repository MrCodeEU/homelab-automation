#!/usr/bin/env bash
set -euo pipefail
TARGET="nas-mgmt"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'bash -s' < "$DIR/schedule-remote-check.sh"
