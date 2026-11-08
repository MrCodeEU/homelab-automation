#!/usr/bin/env bash
# Restarts the controller when it needs it and creates the default admin
# once.
#
# The restart has two jobs: compose-deploy.sh does not recreate the
# container when only the bind-mounted config.yml changes (same as ntfy's
# hook), and every start re-issues the controller leaf certs from the
# intermediate. A restart drops the routers' control channels and every
# circuit for ~10 s (Caddy's Ziti upstreams answered 502, 2026-11-08), so it
# no longer runs on every deploy: only when config.yml differs from the one
# the controller was last restarted with, or a leaf cert expires within 30
# days.
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

stamp=.config-restarted.sha256
want=$(sha256sum config.yml | cut -d' ' -f1)
leaf=data/pki/intermediate/certs
if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ] \
  && openssl x509 -checkend $((30 * 86400)) -noout -in "$leaf/server.cert" >/dev/null \
  && openssl x509 -checkend $((30 * 86400)) -noout -in "$leaf/client.cert" >/dev/null; then
  echo "ziti-controller: config unchanged, leaf certs valid for 30+ days - not restarted"
else
  docker restart ziti-controller >/dev/null
  printf '%s\n' "$want" >"$stamp"
  echo "ziti-controller: restarted"
fi

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
