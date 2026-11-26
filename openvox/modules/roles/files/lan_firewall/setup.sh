#!/bin/bash
# Managed by OpenVox (roles::lan_firewall, roles::nas_lan_firewall).
#
# Loads the HOMELAB-INPUT chain from rules.v4 / rules.v6 next to this
# script and hooks it into INPUT (first rule when it has to add the jump).
# The chain is the only thing it touches: vendor chains (UGOS's UG_*,
# Tailscale's ts-input, Docker's) stay as they are.
#
# Each rules file carries @SHA@, replaced by the first 16 hex of its own
# sha256 and stored in the chain's first rule as a comment, so a rerun only
# reloads when the file changed.
#
#   setup.sh          load what is missing or changed
#   setup.sh --check  exit 1 when a reload or the jump is missing
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
check=false
[ "${1:-}" = --check ] && check=true
rc=0

for fam in 4 6; do
  ipt=iptables
  [ "$fam" = 6 ] && ipt=ip6tables
  rules="$dir/rules.v$fam"
  want=$(sha256sum < "$rules" | cut -c1-16)
  have=$("$ipt" -S HOMELAB-INPUT 2>/dev/null \
    | sed -n 's/.*homelab-sha=\([0-9a-f]*\).*/\1/p' | head -n 1 || true)
  hooked=true
  "$ipt" -C INPUT -j HOMELAB-INPUT 2>/dev/null || hooked=false
  # A rule added or deleted by hand keeps the sha comment: count the rules.
  if [ -n "$have" ] && [ "$("$ipt" -S HOMELAB-INPUT | grep -c '^-A ')" != "$(grep -c '^-A ' "$rules")" ]; then
    have=changed
  fi

  if $check; then
    if [ "$want" != "$have" ] || ! $hooked; then
      echo "HOMELAB-INPUT (IPv$fam) needs a reload or its INPUT jump"
      rc=1
    fi
    continue
  fi

  if [ "$want" != "$have" ]; then
    # --noflush keeps every other chain; the chain declared in the file is
    # flushed and refilled.
    sed "s/@SHA@/$want/" "$rules" | "$ipt-restore" --noflush
    echo "HOMELAB-INPUT (IPv$fam) loaded, sha $want"
  fi
  if ! $hooked; then
    "$ipt" -I INPUT 1 -j HOMELAB-INPUT
    echo "HOMELAB-INPUT (IPv$fam) hooked into INPUT"
  fi
done
exit "$rc"
