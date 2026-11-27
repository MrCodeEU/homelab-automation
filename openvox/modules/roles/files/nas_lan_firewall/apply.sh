#!/usr/bin/env bash
# Copies the staged firewall files to nas's array and runs setup.sh there.
set -euo pipefail
TARGET="nas-mgmt"
STAGE=/var/lib/openvox-nas-lan-firewall
BASE=/mnt/user/appdata/homelab/lan-firewall

ssh -o BatchMode=yes "$TARGET" "install -d -m 0700 $BASE"
scp -q -o BatchMode=yes "$STAGE/setup.sh" "$STAGE/rules.v4" "$STAGE/rules.v6" "$STAGE/rules.fwd.v4" "$TARGET:$BASE/"
ssh -o BatchMode=yes "$TARGET" "bash $BASE/setup.sh"
