#!/usr/bin/env bash
# Read-only orphan detection for roles::services' cleanup exec. Exit 1
# (triggers cleanup-apply.sh) only when at least one orphaned service
# directory is found; exit 0 otherwise.
#
# Split from cleanup-apply.sh per this migration's noop-safety rule: an
# exec without `unless` runs its command for real even under --noop,
# which would be unacceptable for a script that stops containers and
# deletes directories (same reasoning as tutabridge-cli's
# keyring-lock-check/apply split).
#
# Args: $1 = base_path, $2 = comma-separated catalog of ALL service
# names, $3 = comma-separated names of THIS host's currently-active
# services. A directory is orphaned when its name is a known catalog
# service (avoids touching unrelated dirs like mailcow-dockerized) but
# is NOT among this host's active names.
set -uo pipefail
base_path="$1"
all_names="$2"
host_names="$3"

IFS=',' read -ra all_arr <<< "$all_names"
IFS=',' read -ra host_arr <<< "$host_names"

orphans=0
while IFS= read -r -d '' compose; do
  dir=$(dirname "$compose")
  name=$(basename "$dir")

  is_known=false
  for n in "${all_arr[@]}"; do [ "$n" = "$name" ] && is_known=true && break; done
  $is_known || continue

  is_active=false
  for n in "${host_arr[@]}"; do [ "$n" = "$name" ] && is_active=true && break; done
  $is_active && continue

  echo "orphan detected: ${name} (${dir})" >&2
  orphans=$((orphans + 1))
done < <(find "$base_path" -mindepth 2 -maxdepth 2 -name docker-compose.yml -type f -print0 2>/dev/null)

[ "$orphans" -eq 0 ]
