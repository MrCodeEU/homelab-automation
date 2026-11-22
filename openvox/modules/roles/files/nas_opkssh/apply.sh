#!/usr/bin/env bash
# Copies the staged opkssh files to nas's array and runs setup.sh there.
set -euo pipefail
TARGET="nas-mgmt"
STAGE=/var/lib/openvox-nas-opkssh
BASE=/mnt/user/appdata/homelab/opkssh

ssh -o BatchMode=yes "$TARGET" "install -d -m 0700 $BASE $BASE/etc"
scp -q -o BatchMode=yes "$STAGE/opkssh" "$STAGE/setup.sh" "$TARGET:$BASE/"
scp -q -o BatchMode=yes "$STAGE/etc/providers" "$STAGE/etc/auth_id" "$STAGE/etc/config.yml" "$TARGET:$BASE/etc/"
ssh -o BatchMode=yes "$TARGET" "bash $BASE/setup.sh"
