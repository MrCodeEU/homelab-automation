#!/usr/bin/env bash
# Synchronise deployable service assets from the canonical services/ tree into
# the vendored OpenVox module tree. Puppet cannot read controller-side files at
# apply time, so these copies are necessary; this script makes their upkeep
# deterministic instead of manual.
#
# Usage: scripts/sync-openvox-service-files.sh [check|sync]
#   check - fail when the vendored tree would change (default; CI/pre-commit)
#   sync  - update the vendored tree from services/
set -euo pipefail

mode="${1:-check}"
case "$mode" in
  check|sync) ;;
  *) echo "usage: $0 [check|sync]" >&2; exit 2 ;;
esac

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

mapfile -t production_services < <(
  python3 - <<'PY'
import re
import yaml

for service in yaml.safe_load(open('openvox/data/common.yaml'))['services_catalog']:
    if (service.get('managed', True) and not service.get('skip_deploy', False)
            and service.get('host') in {'mljr', 'nuc', 'ugreen'}):
        name = service['name']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
            raise SystemExit(f'unsafe service name in catalog: {name!r}')
        print(name)
PY
)

mapfile -t staging_services < <(
  python3 - <<'PY'
import re
import yaml

for service in yaml.safe_load(open('openvox/data/common.yaml'))['services_catalog']:
    if service.get('staging'):
        name = service['name']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
            raise SystemExit(f'unsafe service name in catalog: {name!r}')
        print(name)
PY
)

sync_tree() {
  local source="$1" destination="$2" label="$3"
  if [[ ! -d "$source" ]]; then
    echo "missing canonical ${label} source: $source" >&2
    return 1
  fi
  if [[ ! -d "$destination" ]]; then
    echo "missing OpenVox ${label} destination: $destination" >&2
    return 1
  fi

  # These are repository-only material, not service runtime assets. Exclude
  # them from both comparison and deletion so documentation and tests can stay
  # local without leaking into every managed host.
  local -a rsync_args=(-a --checksum --no-times --omit-dir-times --delete
    --exclude=/dev/
    --exclude=/README.md
    --exclude=/tests/
    --exclude=/.pytest_cache/
    --exclude=/.env.example)
  if [[ "$mode" == check ]]; then
    local changes
    changes=$(rsync -ani "${rsync_args[@]}" "$source/" "$destination/")
    if [[ -n "$changes" ]]; then
      echo "OpenVox ${label} tree is out of sync: $destination" >&2
      printf '%s\n' "$changes" >&2
      return 1
    fi
  else
    rsync "${rsync_args[@]}" "$source/" "$destination/"
  fi
}

for service in "${production_services[@]}"; do
  sync_tree "services/$service" "openvox/modules/roles/files/services/$service" "production service '$service'"
done

for service in "${staging_services[@]}"; do
  sync_tree "services/$service/dev" "openvox/modules/roles/files/services_staging/$service" "staging service '$service'"
done

if [[ "$mode" == check ]]; then
  echo "OpenVox service assets are in sync."
fi
