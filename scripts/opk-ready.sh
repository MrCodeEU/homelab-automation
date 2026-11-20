#!/usr/bin/env bash
# Makes sure the laptop has a usable opkssh key before a script SSHes to a
# host over Ziti (root@<host>.ziti, docs/ZITI_ENROLL.md). `opkssh login`
# writes ~/.ssh/id_ecdsa and its certificate; ssh offers them by default.
#
# The certificate says "Valid: forever": the hosts enforce the 24h from
# /etc/opk/providers against the ID token's issue time, which is the
# login. So the age of the certificate file decides. Less than
# OPK_MIN_LEFT seconds (default 600) left, or no key: with a terminal run
# `opkssh login`, otherwise fail with what to run.
#
# OPK_SKIP=1 skips the check (a YubiKey key, or a caller that checked).
set -euo pipefail

[ "${OPK_SKIP:-}" = 1 ] && exit 0

cert="${OPK_CERT:-$HOME/.ssh/id_ecdsa-cert.pub}"
max_age="${OPK_MAX_AGE:-86400}"
min_left="${OPK_MIN_LEFT:-600}"

left=-1
if [ -f "$cert" ] && ssh-keygen -L -f "$cert" 2>/dev/null | grep -q 'opkssh-wildcard'; then
  left=$((max_age - ($(date +%s) - $(stat -c %Y "$cert"))))
fi
[ "$left" -ge "$min_left" ] && exit 0

if [ "$left" -lt 0 ]; then
  why="no valid opkssh key"
else
  why="opkssh key expires in $((left / 60)) min"
fi
if [ -t 0 ] && [ -t 2 ] && command -v opkssh >/dev/null; then
  echo "$why, running opkssh login" >&2
  exec opkssh login
fi
echo "$why: run \`opkssh login\` (or OPK_SKIP=1 with another key)" >&2
exit 1
