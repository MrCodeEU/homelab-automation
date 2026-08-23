#!/usr/bin/env bash
# Pushes a service directory staged locally on nuc (by Puppet's own
# `file { recurse => remote }`, same primitive rocky/ugreen use directly -
# nas just can't run the agent that would apply it there itself) to nas
# over rsync. Unraid runs real rsync (unlike UGOS, which blocks
# --server mode - see scripts/openvox-sync.sh's own ugreen branch), so
# no scp fallback is needed here.
#
# Unconditional, no unless-guard: rsync itself is idempotent (only
# transfers what actually changed), same accepted shape as
# compose-deploy.sh relying on `docker compose up` being idempotent.
# --delete matches Ansible's own rsync --delete for this same directory
# (roles/services/tasks/prepare_service.yml's non-ugreen branch).
set -euo pipefail
local_dir="$1"
remote_dir="$2"
TARGET="root@nas.tail33930.ts.net"

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "mkdir -p '${remote_dir}'"
rsync -az --delete -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
  "${local_dir}/" "${TARGET}:${remote_dir}/"
