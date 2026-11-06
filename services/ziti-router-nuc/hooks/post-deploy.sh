#!/usr/bin/env bash
# Restarts the router once it is enrolled: compose-deploy.sh does not
# recreate the container for a config.yml change alone (same as ntfy's
# hook), and each start renews the router certificate (--extend).
set -euo pipefail

if [ ! -s data/nuc.cert ]; then
  echo "WARNING: router nuc is not enrolled yet - run scripts/ziti-enroll-router.sh nuc." >&2
  exit 0
fi
docker restart ziti-router-nuc >/dev/null
echo "ziti-router-nuc: restarted"
