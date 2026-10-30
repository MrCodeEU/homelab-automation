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
  # Compose v5 builds through buildx bake, which refuses `build.network: host`
  # without an --allow network.host entitlement the compose CLI cannot pass.
  # mljr needs host networking for builds (its default-bridge build
  # containers inherit the host's MagicDNS resolver, unreachable from the
  # bridge, so every `apk add` / `git clone` step fails with a DNS error).
  # Services that ask for it are built with plain `docker build --network
  # host`; everything else still goes through `docker compose build`.
  host_net_builds=$(docker compose "${compose_args[@]}" config --format json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
for name, svc in cfg.get("services", {}).items():
    build = svc.get("build")
    if isinstance(build, dict) and build.get("network") == "host":
        print("\t".join([name, svc.get("image", ""), build.get("context", "."), build.get("dockerfile", "Dockerfile")]))
')
  if [ -z "$host_net_builds" ]; then
    docker compose "${compose_args[@]}" build
  else
    other_services=()
    while IFS=$'\t' read -r svc_name svc_image svc_context svc_dockerfile; do
      [ -n "$svc_name" ] || continue
      [ -n "$svc_image" ] || { echo "service $svc_name: build.network host needs an explicit image: name" >&2; exit 1; }
      docker build --network host -f "$svc_context/$svc_dockerfile" -t "$svc_image" "$svc_context"
    done <<< "$host_net_builds"
    while IFS= read -r svc_name; do
      grep -q "^${svc_name}"$'\t' <<< "$host_net_builds" || other_services+=("$svc_name")
    done < <(docker compose "${compose_args[@]}" config --services)
    if [ "${#other_services[@]}" -gt 0 ]; then
      docker compose "${compose_args[@]}" build "${other_services[@]}"
    fi
  fi
  docker compose "${compose_args[@]}" up -d --remove-orphans
else
  docker compose "${compose_args[@]}" pull --quiet
  docker compose "${compose_args[@]}" up -d --remove-orphans
fi
