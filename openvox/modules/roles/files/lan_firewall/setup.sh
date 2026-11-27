#!/bin/bash
# Managed by OpenVox (roles::lan_firewall, roles::nas_lan_firewall).
#
# Loads the chains from the rules files next to this script and hooks each
# into its parent chain (first rule when it has to add the jump):
#
#   HOMELAB-INPUT    in INPUT        rules.v4, rules.v6
#   HOMELAB-FORWARD  in DOCKER-USER  rules.fwd.v4 (containers to the LAN)
#
# A rules file that is not there is skipped; a parent chain that is not
# there yet (DOCKER-USER before Docker started) is skipped too, the next
# timer run retries. Only these chains are touched: vendor chains (UGOS's
# UG_*, Tailscale's ts-input, Docker's) stay as they are.
#
# Each rules file carries @SHA@, replaced by the first 16 hex of its own
# sha256 and stored in the chain's first rule as a comment, so a rerun only
# reloads when the file changed. A rule count catches a rule added or
# deleted by hand.
#
#   setup.sh          load what is missing or changed
#   setup.sh --check  exit 1 when a reload or a jump is missing
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
check=false
[ "${1:-}" = --check ] && check=true
rc=0

specs=(
  "HOMELAB-INPUT INPUT rules 4 6"
  "HOMELAB-FORWARD DOCKER-USER rules.fwd 4"
)

for spec in "${specs[@]}"; do
  read -r chain parent prefix families <<<"$spec"
  for fam in $families; do
    ipt=iptables
    [ "$fam" = 6 ] && ipt=ip6tables
    rules="$dir/$prefix.v$fam"
    [ -f "$rules" ] || continue
    if ! "$ipt" -S "$parent" >/dev/null 2>&1; then
      echo "$parent (IPv$fam) not there yet, $chain waits for the next run"
      continue
    fi

    want=$(sha256sum < "$rules" | cut -c1-16)
    have=$("$ipt" -S "$chain" 2>/dev/null \
      | sed -n 's/.*homelab-sha=\([0-9a-f]*\).*/\1/p' | head -n 1 || true)
    hooked=true
    "$ipt" -C "$parent" -j "$chain" 2>/dev/null || hooked=false
    # A rule added or deleted by hand keeps the sha comment: count the rules.
    if [ -n "$have" ] && [ "$("$ipt" -S "$chain" | grep -c '^-A ')" != "$(grep -c '^-A ' "$rules")" ]; then
      have=changed
    fi

    if $check; then
      if [ "$want" != "$have" ] || ! $hooked; then
        echo "$chain (IPv$fam) needs a reload or its $parent jump"
        rc=1
      fi
      continue
    fi

    if [ "$want" != "$have" ]; then
      # --noflush keeps every other chain; the chain declared in the file
      # is flushed and refilled.
      sed "s/@SHA@/$want/" "$rules" | "$ipt-restore" --noflush
      echo "$chain (IPv$fam) loaded, sha $want"
    fi
    if ! $hooked; then
      "$ipt" -I "$parent" 1 -j "$chain"
      echo "$chain (IPv$fam) hooked into $parent"
    fi
  done
done
exit "$rc"
