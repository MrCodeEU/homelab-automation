#!/usr/bin/env bash
# Restarts Alloy when config.alloy changed: compose-deploy.sh does not
# recreate the container for a bind-mounted file change alone (same as
# ziti-router-nas's hook), so a new config only took effect at the next
# reboot (2026-11-22: still pushing to nuc's tailnet IP after #691). The
# WAL is on the alloy-data volume, so a restart loses no samples.
set -euo pipefail

stamp=.config-restarted.sha256
want=$(sha256sum config.alloy | cut -d' ' -f1)
if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
  echo "nas-alloy: config unchanged - not restarted"
  exit 0
fi
docker restart nas-alloy >/dev/null
printf '%s\n' "$want" >"$stamp"
echo "nas-alloy: restarted"
