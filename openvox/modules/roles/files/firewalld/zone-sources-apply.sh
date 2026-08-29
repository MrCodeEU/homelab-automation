#!/usr/bin/env bash
set -euo pipefail
zone="$1"; shift
for scope in '' --permanent; do
  current=$(firewall-cmd $scope --zone="$zone" --list-sources)
  for source in $current; do
    keep=false
    for wanted in "$@"; do [ "$source" = "$wanted" ] && keep=true; done
    "$keep" || firewall-cmd $scope --zone="$zone" --remove-source="$source"
  done
  for source in "$@"; do
    firewall-cmd $scope --zone="$zone" --query-source="$source" >/dev/null || firewall-cmd $scope --zone="$zone" --add-source="$source"
  done
done
