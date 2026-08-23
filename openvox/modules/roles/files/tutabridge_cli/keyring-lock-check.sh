#!/usr/bin/env bash
# Self-healing: if the on-disk login.keyring was ever created with a
# different passphrase than the current one (an old manual test, or a
# rotated vault secret), gnome-keyring-daemon starts fine but the
# collection silently stays locked forever - this is exactly the bug
# that blocked the very first version of the original Ansible role.
#
# Split into check/apply (rather than one always-run script with
# internal branching) specifically so the destructive reset in
# keyring-lock-apply.sh is skipped, not executed, under --noop - an
# exec without `unless` runs its command for real even during a noop
# pass (confirmed live elsewhere in this migration for read-only
# diagnostic execs, which is safe for them but would NOT be safe for
# this script's mutating branch).
set -uo pipefail
LOCKED=$(XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  gdbus call --session \
    --dest org.freedesktop.secrets \
    --object-path /org/freedesktop/secrets/collection/login \
    --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.Secret.Collection Locked 2>/dev/null || true)
case "$LOCKED" in
  *true*) exit 1 ;;
  *)      exit 0 ;;
esac
