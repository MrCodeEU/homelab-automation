#!/usr/bin/env bash
# Restarts the router once it is enrolled: compose-deploy.sh does not
# recreate the container for a config.yml change alone (same as ntfy's
# hook), and each start renews the router certificate (--extend).
set -euo pipefail

if [ ! -s data/mljr.cert ]; then
  echo "WARNING: router mljr is not enrolled yet - run scripts/ziti-enroll-router.sh mljr." >&2
  exit 0
fi
docker restart ziti-router >/dev/null
echo "ziti-router: restarted"
