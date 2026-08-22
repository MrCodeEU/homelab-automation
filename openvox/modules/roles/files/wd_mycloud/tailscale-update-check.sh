#!/usr/bin/env bash
# Exits 0 (no work needed) if wd-mycloud's tailscale is already at the
# latest stable release. Latest-version lookup happens here on the proxy
# host (real curl/python3), not on wd-mycloud's busybox - simpler, same
# data. Deployed by roles::wd_mycloud_proxy; used as an exec unless-guard.
set -euo pipefail
TARGET="root@wd-mycloud.tail33930.ts.net"
BASE="/mnt/HD/HD_a2/tailscale"

LATEST_VERSION=$(curl -s "https://pkgs.tailscale.com/stable/?mode=json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['TarballsVersion'])")

CURRENT_VERSION=$(ssh -o BatchMode=yes "$TARGET" \
  "[ -x $BASE/current/tailscale ] && $BASE/current/tailscale version | head -1 || echo none")

[ "$CURRENT_VERSION" = "$LATEST_VERSION" ]
