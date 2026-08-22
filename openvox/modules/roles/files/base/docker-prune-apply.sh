#!/usr/bin/env bash
# Only included in the catalog when docker_prune_enabled is true (see
# roles::base) - default off fleet-wide, same as the Ansible role.
set -euo pipefail
docker container prune -f
docker image prune -f
docker builder prune -f
