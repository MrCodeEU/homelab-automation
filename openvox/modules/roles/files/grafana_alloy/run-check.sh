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

RUNNING_IMAGE=$(docker inspect grafana-alloy --format '{{.Image}}')
LOCAL_LATEST_IMAGE=$(docker inspect grafana/alloy:latest --format '{{.Id}}' 2>/dev/null || true)

# A guard must stay read-only because Puppet evaluates it during --noop.
# Query Docker Hub's manifest digest rather than using `docker pull`, then
# compare it with the cached tag. A registry outage does not force a recreate;
# the next run will check again.
[ -n "$LOCAL_LATEST_IMAGE" ] && [ "$RUNNING_IMAGE" = "$LOCAL_LATEST_IMAGE" ] || exit 1

TOKEN=$(curl -fsS 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:grafana/alloy:pull' \
  | jq -r '.token // empty' 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  REMOTE_DIGEST=$(curl -fsSI \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    'https://registry-1.docker.io/v2/grafana/alloy/manifests/latest' \
    | awk 'BEGIN { IGNORECASE=1 } /^docker-content-digest:/ { gsub("\\r", "", $2); print $2 }' \
    | tail -1)
  LOCAL_DIGEST=$(docker inspect grafana/alloy:latest --format '{{join .RepoDigests "\n"}}' \
    | sed -n 's/.*@//p' | head -1)
  [ -z "$REMOTE_DIGEST" ] || [ "$REMOTE_DIGEST" = "$LOCAL_DIGEST" ]
fi
