#!/usr/bin/env bash
# Installs $OPENVOX_NAS_MGMT_ENTRY in nas's root authorized_keys, replacing
# any older line for the same key (see key-check.sh). It connects as
# nas-mgmt, i.e. with this key over Ziti, so it can only replace an entry
# whose key still logs in (options such as from= changed). The first
# install, or one after the key was rotated, goes through the recovery key:
# docs/DISASTER_RECOVERY.md.
set -euo pipefail
TARGET="nas-mgmt"
ENTRY_B64=$(printf '%s' "${OPENVOX_NAS_MGMT_ENTRY}" | base64 -w0)

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$ENTRY_B64" <<'REMOTE'
set -euo pipefail
ENTRY=$(printf '%s' "$1" | base64 -d)
KEY=$(printf '%s' "$ENTRY" | grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+')
AUTH=/root/.ssh/authorized_keys
FILE=$(readlink -f "$AUTH")
{ grep -vF "$KEY" "$FILE" 2>/dev/null || true; printf '%s\n' "$ENTRY"; } > "$FILE.openvox-tmp"
chmod 600 "$FILE.openvox-tmp"
mv "$FILE.openvox-tmp" "$FILE"
echo "authorized homelab-nas-mgmt in $FILE"
REMOTE
