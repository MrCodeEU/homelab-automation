#!/usr/bin/env bash
# Runs a service's own hooks/post-deploy.sh after its container is up -
# ported from ansible/roles/services/tasks/main.yml's post-deploy hook
# loop. Args: $1 = service name, $2 = deploy_path, $3 = "true"/"false"
# (critical - matches Ansible's critical_hook_services).
#
# Deliberately no `set -e`: a non-critical hook's failure must not fail
# this exec (Ansible's own failed_when: false, gated back on by
# critical_hook_services). The hook script itself is expected to be
# idempotent - it's re-run unconditionally on every apply, same as
# compose-deploy.sh.
set -uo pipefail
svc_name="$1"
deploy_path="$2"
critical="${3:-false}"

cd "$deploy_path"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

export SERVICE_NAME="$svc_name"
export SERVICE_PATH="$deploy_path"

bash "${deploy_path}/hooks/post-deploy.sh" "$svc_name" "$deploy_path"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "WARNING: post-deploy hook for ${svc_name} failed (rc=${rc})" >&2
  if [ "$critical" = "true" ]; then
    exit "$rc"
  fi
fi
exit 0
