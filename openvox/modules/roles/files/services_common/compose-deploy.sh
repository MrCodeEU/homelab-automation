#!/usr/bin/env bash
# Shared compose-up script for every roles::services::service instance -
# one generic script instead of ~30 near-identical per-service copies.
# Args: $1 = deploy_path, $2 = "true"/"false" (service.build_from_source)
#
# Unconditional, no unless-guard: `docker compose up -d` is itself
# idempotent (only recreates a container when its resolved spec actually
# changed) - same accepted shape as roles::mailcow's mailcow-services-up.
set -euo pipefail
deploy_path="$1"
build_from_source="${2:-false}"

cd "$deploy_path"

if [ "$build_from_source" = "true" ]; then
  docker compose build
  docker compose up -d --remove-orphans
else
  docker compose pull --quiet
  docker compose up -d --remove-orphans
fi
