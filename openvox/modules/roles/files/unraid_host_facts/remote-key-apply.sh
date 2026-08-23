#!/usr/bin/env bash
# Runs ON nas via ssh. $1 = the full authorized_keys line to install
# (same shape/scoping as remote-key-check.sh).
set -euo pipefail
ENTRY="$1"
AUTH_KEYS=/root/.ssh/authorized_keys
KEY_LINE=$(echo "$ENTRY" | awk '{print $2, $3}')

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ -f "$AUTH_KEYS" ]; then
  grep -vF "$KEY_LINE" "$AUTH_KEYS" > "${AUTH_KEYS}.openvox-tmp" || true
else
  : > "${AUTH_KEYS}.openvox-tmp"
fi
echo "$ENTRY" >> "${AUTH_KEYS}.openvox-tmp"
mv "${AUTH_KEYS}.openvox-tmp" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
echo "authorized homelab-healthreport key in $AUTH_KEYS"
