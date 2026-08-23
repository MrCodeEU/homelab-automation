#!/usr/bin/env bash
# Read-only checksum comparison for roles::services' Kuma auto-provisioning
# exec. Exit 0 (skip provisioning) when the stored checksum already
# matches the catalog's current hash; exit 1 (run kuma-provision-apply.sh)
# otherwise, including when no checksum has ever been stored.
#
# Split from kuma-provision-apply.sh per this migration's noop-safety rule
# (an exec without `unless` runs for real even under --noop, which would
# fire real Uptime Kuma API calls during a dry run).
#
# Args: $1 = kuma_dir, $2 = current catalog hash.
set -uo pipefail
kuma_dir="$1"
new_hash="$2"

stored="$(cat "${kuma_dir}/.services-checksum" 2>/dev/null || true)"
[ "$stored" = "$new_hash" ]
