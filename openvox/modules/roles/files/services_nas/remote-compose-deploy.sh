#!/usr/bin/env bash
# `docker compose up` on nas, run via SSH from nuc. DOCKER_CONFIG points at
# the array-persisted credentials (see ghcr-login-apply.sh) so a private
# pull (auto-media-sort) can authenticate; harmless for the public images
# the other 3 nas services use.
#
# Unconditional, no unless-guard - same reasoning as compose-deploy.sh's
# own rocky/ugreen sibling: `docker compose up -d` is itself idempotent.
#
# The compose run is detached from the SSH session (setsid nohup) and
# leaves its exit code in a status file, which is then polled over fresh
# connections. nas-mgmt goes over Ziti through nas's own router, so
# recreating ziti-router-nas cut the session that was doing it: on
# 2026-11-24 (router 2.0.9) the old container was gone, the new one never
# started, and nas was off the mesh until it was started by hand.
set -euo pipefail
remote_dir="$1"
build_from_source="${2:-false}"
TARGET="nas-mgmt"
BASE=/mnt/user/appdata/homelab
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$TARGET")

compose="DOCKER_CONFIG=${BASE}/.docker docker compose"
if [ "$build_from_source" = "true" ]; then
  steps="${compose} build && ${compose} up -d --remove-orphans"
else
  steps="${compose} pull --quiet && ${compose} up -d --remove-orphans"
fi

# Status and log live in the service directory; one run at a time per service.
run="${remote_dir}/.openvox-deploy"
"${SSH[@]}" "cd '${remote_dir}' && rm -f '${run}.status' && setsid nohup sh -c '${steps}; echo \$? > ${run}.status' > '${run}.log' 2>&1 < /dev/null &"

# Until shortly before the exec's 300 s timeout (roles::services_nas::service);
# SSH failures while the router comes back are expected and retried.
while [ "$SECONDS" -lt 280 ]; do
  sleep 5
  status=$("${SSH[@]}" "cat '${run}.status' 2>/dev/null" 2>/dev/null) || continue
  [ -n "$status" ] || continue
  if [ "$status" = 0 ]; then
    exit 0
  fi
  echo "FAILED: compose in ${remote_dir} exited ${status}:" >&2
  "${SSH[@]}" "tail -n 30 '${run}.log'" >&2 || true
  exit 1
done
echo "FAILED: no result from compose in ${remote_dir} after 280 s" >&2
exit 1
