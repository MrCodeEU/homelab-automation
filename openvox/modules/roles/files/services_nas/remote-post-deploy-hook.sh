#!/usr/bin/env bash
# Runs a nas-hosted service's own hooks/post-deploy.sh, via SSH from nuc
# (proxy-exec - the hook uses `docker exec` against nas's own docker.sock,
# so it must actually run on nas, not nuc). Mirrors post-deploy-hook.sh's
# rocky/ugreen sibling: sources .env, exports SERVICE_NAME/SERVICE_PATH,
# swallows a non-critical failure (none of the 4 managed nas services are
# in critical_hook_services today, so this only ever takes the warning
# path - kept for parity with the shared design anyway).
set -uo pipefail
svc_name="$1"
remote_dir="$2"
critical="${3:-false}"
TARGET="root@nas.tail33930.ts.net"

remote_script=$(cat <<REMOTE
set -uo pipefail
cd '${remote_dir}'
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
export SERVICE_NAME='${svc_name}'
export SERVICE_PATH='${remote_dir}'
bash '${remote_dir}/hooks/post-deploy.sh' '${svc_name}' '${remote_dir}'
REMOTE
)

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "$remote_script"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "WARNING: post-deploy hook for ${svc_name} failed (rc=${rc})" >&2
  if [ "$critical" = "true" ]; then
    exit "$rc"
  fi
fi
exit 0
