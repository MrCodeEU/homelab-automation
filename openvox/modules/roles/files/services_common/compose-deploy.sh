#!/usr/bin/env bash
# Shared compose-up script for every roles::services::service instance -
# one generic script instead of ~30 near-identical per-service copies.
# Args: $1 = deploy_path, $2 = "true"/"false" (service.build_from_source),
# $3 = optional compose project name override.
#
# $3 exists for staging instances only: their container_name fields
# (services/<name>/dev/docker-compose.yml) hardcode a
# `${COMPOSE_PROJECT_NAME:-<name>-staging}` fallback, and the containers
# already live in production were deployed with that exact project name
# ("homepage-staging" etc, confirmed via `docker inspect
# com.docker.compose.project` before this script gained the arg) - not
# passing `-p` here left `docker compose` default to the directory
# basename ("homepage"), a different project identity that fought the
# existing container over the same host port instead of adopting it.
# Every non-staging caller omits $3, so plain prod services keep
# resolving their project name from the directory basename exactly as
# before.
#
# Unconditional, no unless-guard: `docker compose up -d` is itself
# idempotent (only recreates a container when its resolved spec actually
# changed) - same accepted shape as roles::mailcow's mailcow-services-up.
set -euo pipefail
deploy_path="$1"
build_from_source="${2:-false}"
project_name="${3:-}"

cd "$deploy_path"

compose_args=()
if [ -n "$project_name" ]; then
  compose_args=(-p "$project_name")
fi

if [ "$build_from_source" = "true" ]; then
  docker compose "${compose_args[@]}" build
  docker compose "${compose_args[@]}" up -d --remove-orphans
else
  docker compose "${compose_args[@]}" pull --quiet
  docker compose "${compose_args[@]}" up -d --remove-orphans
fi
