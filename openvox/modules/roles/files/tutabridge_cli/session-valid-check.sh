#!/usr/bin/env bash
# unless-guard for tutabridge-first-login: skip (exit 0, no re-login)
# only when the marker is present AND the keyring still actually holds
# a saved tutabridge session - not just the marker on its own, which
# used to go stale silently. tutabridge-cli deletes the keyring item on
# certain resume failures without touching Puppet's marker (hit live
# 2026-09-15 to 2026-09-20, when every login attempt failed on Tuta's
# 474 Invalid Software Version and wiped the saved session each time).
# Re-triggers first-login.sh whenever the keyring item is gone, marker
# or not, so this self-heals instead of silently staying broken.
set -uo pipefail
MARKER=/opt/tutabridge/.first-login-done
[ -f "$MARKER" ] || exit 1

ITEMS=$(XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  gdbus call --session \
    --dest org.freedesktop.secrets \
    --object-path /org/freedesktop/secrets/collection/login \
    --method org.freedesktop.Secret.Collection.SearchItems \
    "{'service': 'tutabridge'}" 2>/dev/null) || exit 1

[ -n "$ITEMS" ] && [ "$ITEMS" != '(@ao [],)' ]
