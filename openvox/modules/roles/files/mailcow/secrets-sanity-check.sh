#!/usr/bin/env bash
# Read-only guard, not a mutation - runs every apply (no separate apply
# script). Confirms mailcow.conf's generated secrets weren't corrupted
# by a bad edit, same guarantee as the Ansible role's own
# extract-then-assert dance, without the ceremony.
set -euo pipefail
CONF=/opt/mailcow-dockerized/mailcow.conf
[ -f "$CONF" ] || exit 0
for key in DBPASS DBROOT REDISPASS; do
  val=$(grep "^${key}=" "$CONF" | head -1 | cut -d= -f2-)
  if [ -z "$val" ]; then
    echo "ERROR: $key is empty/missing in $CONF - possible config corruption" >&2
    exit 1
  fi
done
