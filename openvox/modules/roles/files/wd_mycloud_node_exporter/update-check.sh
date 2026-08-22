#!/usr/bin/env bash
# Exits 0 (no work needed) if wd-mycloud's node_exporter is already at the
# latest stable release. Latest-version lookup happens here on the proxy
# host (real curl/python3), not on wd-mycloud's busybox - simpler, same
# data. Deployed by roles::wd_mycloud_node_exporter_proxy; used as an
# exec unless-guard.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
BASE="/mnt/HD/HD_a2/node_exporter"

LATEST_JSON=$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest)
LATEST_VERSION=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

CURRENT_VERSION=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "[ -x $BASE/current/node_exporter ] && $BASE/current/node_exporter --version 2>&1 | head -1 | sed -n 's/.*version \\([0-9.]*\\).*/\\1/p' || echo none")

[ "$CURRENT_VERSION" = "$LATEST_VERSION" ]
