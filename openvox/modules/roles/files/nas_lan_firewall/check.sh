#!/usr/bin/env bash
# Exits 0 (no work needed) if nas has the files staged on nuc, unchanged,
# and setup.sh finds the chain loaded and hooked (see setup.sh).
set -euo pipefail
TARGET="nas-mgmt"
STAGE=/var/lib/openvox-nas-lan-firewall
BASE=/mnt/user/appdata/homelab/lan-firewall

want=$(cd "$STAGE" && sha256sum setup.sh rules.v4 rules.v6 rules.fwd.v4)
have=$(ssh -o BatchMode=yes "$TARGET" "cd $BASE 2>/dev/null && sha256sum setup.sh rules.v4 rules.v6 rules.fwd.v4 2>/dev/null" || true)
[ "$want" = "$have" ]
ssh -o BatchMode=yes "$TARGET" "bash $BASE/setup.sh --check"
