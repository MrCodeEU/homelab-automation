#!/usr/bin/env bash
set -euo pipefail
zone="$1"; shift
expected=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
for scope in '' --permanent; do
  actual=$(firewall-cmd $scope --zone="$zone" --list-sources | tr ' ' '\n' | sed '/^$/d' | sort)
  [ "$actual" = "$expected" ] || exit 1
done
