#!/usr/bin/env bash
# Stops and removes orphaned service directories - ported from
# ansible/roles/services/tasks/cleanup_orphaned.yml. Same detection logic
# as cleanup-check.sh (recomputed, not passed in - the set can't have
# changed between the two in a single apply). A directory is only deleted
# once `docker compose down` for it succeeds; a stuck container leaves the
# directory in place for the next run to retry, matching Ansible's own
# ignore_errors + only-delete-if-stopped-cleanly behavior.
#
# Args: $1 = base_path, $2 = comma-separated ALL catalog service names,
# $3 = comma-separated THIS host's active service names.
set -uo pipefail
base_path="$1"
all_names="$2"
host_names="$3"

IFS=',' read -ra all_arr <<< "$all_names"
IFS=',' read -ra host_arr <<< "$host_names"

removed=0
skipped=0

while IFS= read -r -d '' compose; do
  dir=$(dirname "$compose")
  name=$(basename "$dir")

  is_known=false
  for n in "${all_arr[@]}"; do [ "$n" = "$name" ] && is_known=true && break; done
  $is_known || continue

  is_active=false
  for n in "${host_arr[@]}"; do [ "$n" = "$name" ] && is_active=true && break; done
  $is_active && continue

  echo "CLEANUP: removing orphaned service '${name}' at ${dir}"
  if docker compose -f "${compose}" down --remove-orphans; then
    rm -rf "$dir"
    echo "CLEANUP: removed ${name}"
    removed=$((removed + 1))
  else
    echo "WARNING: failed to stop ${name} - directory NOT removed, investigate with: docker compose -f ${compose} ps" >&2
    skipped=$((skipped + 1))
  fi
done < <(find "$base_path" -mindepth 2 -maxdepth 2 -name docker-compose.yml -type f -print0 2>/dev/null)

echo "CLEANUP SUMMARY: removed ${removed}, skipped ${skipped}"
exit 0
