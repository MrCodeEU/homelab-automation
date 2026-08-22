#!/usr/bin/env bash
# Exits 0 (no work needed) if caddy is installed and no update is
# available. Used as an exec unless-guard.
set -uo pipefail
rpm -q caddy >/dev/null 2>&1 || exit 1
dnf check-update -q caddy >/dev/null 2>&1
[ "$?" != "100" ]
