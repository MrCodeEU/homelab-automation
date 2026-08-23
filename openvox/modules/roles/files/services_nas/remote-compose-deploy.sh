#!/usr/bin/env bash
# `docker compose up` on nas, run via SSH from nuc. DOCKER_CONFIG points at
# the array-persisted credentials (see ghcr-login-apply.sh) so a private
# pull (auto-media-sort) can authenticate; harmless for the public images
# the other 3 nas services use.
#
# Unconditional, no unless-guard - same reasoning as compose-deploy.sh's
# own rocky/ugreen sibling: `docker compose up -d` is itself idempotent.
set -euo pipefail
remote_dir="$1"
build_from_source="${2:-false}"
TARGET="root@nas.tail33930.ts.net"
BASE=/mnt/user/appdata/homelab

if [ "$build_from_source" = "true" ]; then
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
    "cd '${remote_dir}' && DOCKER_CONFIG=${BASE}/.docker docker compose build && DOCKER_CONFIG=${BASE}/.docker docker compose up -d --remove-orphans"
else
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
    "cd '${remote_dir}' && DOCKER_CONFIG=${BASE}/.docker docker compose pull --quiet && DOCKER_CONFIG=${BASE}/.docker docker compose up -d --remove-orphans"
fi
