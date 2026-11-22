#!/usr/bin/env bash
# Exits 0 (no work needed) if nas has the files staged on nuc, unchanged,
# and setup.sh finds them in place (see setup.sh).
set -euo pipefail
TARGET="nas-mgmt"
STAGE=/var/lib/openvox-nas-opkssh
BASE=/mnt/user/appdata/homelab/opkssh

want=$(cd "$STAGE" && sha256sum opkssh setup.sh etc/providers etc/auth_id etc/config.yml)
have=$(ssh -o BatchMode=yes "$TARGET" "cd $BASE 2>/dev/null && sha256sum opkssh setup.sh etc/providers etc/auth_id etc/config.yml 2>/dev/null" || true)
[ "$want" = "$have" ]
ssh -o BatchMode=yes "$TARGET" "bash $BASE/setup.sh --check"
