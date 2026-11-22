#!/usr/bin/env bash
# Exits 0 (no work needed) if wd-mycloud's ziti-edge-tunnel "current" is
# already the pinned release ($1). Deployed by roles::wd_mycloud_ziti_proxy;
# used as an exec unless-guard.
set -euo pipefail
TARGET="wd-mycloud-mgmt"
VERSION="$1"
BASE="/mnt/HD/HD_a2/ziti"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "[ -x $BASE/releases/$VERSION/ziti-edge-tunnel ] && [ \"\$(readlink -f $BASE/current)\" = $BASE/releases/$VERSION ]"
