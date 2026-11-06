#!/usr/bin/env bash
# Restarts the controller and creates the default admin once.
#
# The restart has two jobs: compose-deploy.sh does not recreate the
# container when only the bind-mounted config.yml changes (same as ntfy's
# hook), and every start re-issues the controller leaf certs from the
# intermediate, so each deploy also renews them.
#
# `ziti agent cluster init` talks to the controller's local IPC agent, not
# to the network. It is idempotent: an initialized cluster answers "already
# initialized". ZITI_ADMIN_PASSWORD comes from .env (vault_ziti_admin_password).
set -euo pipefail

if [ ! -s data/pki/intermediate/certs/intermediate.cert ]; then
  echo "WARNING: data/pki has no intermediate yet - run scripts/ziti-sign-intermediate.sh (docs/ZITI_PKI.md)." >&2
  exit 0
fi

if [ -z "${ZITI_ADMIN_PASSWORD:-}" ]; then
  echo "WARNING: ZITI_ADMIN_PASSWORD is empty - add vault_ziti_admin_password for mljr (make add-secret)." >&2
  exit 0
fi

docker restart ziti-controller >/dev/null

out=''
for attempt in $(seq 1 30); do
  if out="$(docker exec ziti-controller ziti agent cluster init admin "$ZITI_ADMIN_PASSWORD" 'Default Admin' 2>&1)" \
    || [[ "$out" == *"already initialized"* ]]; then
    echo "ziti-controller: cluster ready"
    exit 0
  fi
  [ "$attempt" -eq 30 ] && break
  sleep 2
done
echo "FAILED: ziti cluster init: ${out}" >&2
exit 1
