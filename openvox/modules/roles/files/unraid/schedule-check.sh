#!/usr/bin/env bash
set -euo pipefail
TARGET="root@nas.tail33930.ts.net"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  'SCRIPT_NAME=homelab-compose-up FREQUENCY=start RETIRED="GHCR Auth" bash -s' \
  < "$DIR/schedule-remote-check.sh"
