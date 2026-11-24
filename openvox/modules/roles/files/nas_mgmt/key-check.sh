#!/usr/bin/env bash
# Exits 0 (no work needed) if nas's root authorized_keys already holds
# $OPENVOX_NAS_MGMT_ENTRY (set by the exec's environment) exactly. Only that
# one line is compared; every other key on nas is left alone. The entry
# crosses the ssh boundary base64-encoded: it contains double quotes
# (from="..."). /root/.ssh/authorized_keys is a symlink to the flash
# (/boot/config/ssh/root), so it survives a reboot.
set -euo pipefail
TARGET="nas-mgmt"
ENTRY_B64=$(printf '%s' "${OPENVOX_NAS_MGMT_ENTRY}" | base64 -w0)

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$ENTRY_B64" <<'REMOTE'
set -uo pipefail
ENTRY=$(printf '%s' "$1" | base64 -d)
KEY=$(printf '%s' "$ENTRY" | grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+')
grep -F "$KEY" /root/.ssh/authorized_keys 2>/dev/null | grep -qxF "$ENTRY"
REMOTE
