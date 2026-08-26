#!/usr/bin/env bash
# Runs ON nas via ssh. $1 = the full "restrict,...OPTIONS ssh-ed25519 KEY
# homelab-healthreport" line this role owns. Only ever compares against
# that one line - a real stale leftover entry (an old, since-regenerated
# healthreport key, confirmed live on mljr/nuc/nas) is intentionally left
# untouched, this role was never asked to own it.
set -uo pipefail
ENTRY=$(printf '%s' "$1" | base64 -d)
AUTH_KEYS=/root/.ssh/authorized_keys
KEY_LINE=$(echo "$ENTRY" | awk '{print $2, $3}')

if [ -f "$AUTH_KEYS" ] && grep -qF "$KEY_LINE" "$AUTH_KEYS"; then
  CURRENT=$(grep -F "$KEY_LINE" "$AUTH_KEYS")
  [ "$CURRENT" = "$ENTRY" ] && exit 0
fi
exit 1
