#!/usr/bin/env bash
# Real idempotent container management, not glance.pp's always-recreate
# shortcut - matches the already-verified migration/spot port
# (spot/playbooks/grafana-alloy.yml). Recreate only when the config
# content changed (tracked via a stored hash marker, since the running
# container has no other way to expose what config it was started
# with) or the pulled image digest differs from what's currently
# running.
set -uo pipefail
CONFIG=/opt/grafana-alloy/config.alloy
MARKER=/opt/grafana-alloy/.config-hash

docker inspect grafana-alloy >/dev/null 2>&1 || exit 1

CURRENT_HASH=$(sha256sum "$CONFIG" | awk '{print $1}')
STORED_HASH=$(cat "$MARKER" 2>/dev/null || echo "")
[ "$CURRENT_HASH" = "$STORED_HASH" ] || exit 1

docker pull -q grafana/alloy:latest >/dev/null
RUNNING_IMAGE=$(docker inspect grafana-alloy --format '{{.Image}}')
LATEST_IMAGE=$(docker inspect grafana/alloy:latest --format '{{.Id}}')
[ "$RUNNING_IMAGE" = "$LATEST_IMAGE" ]
