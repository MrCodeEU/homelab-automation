#!/usr/bin/env bash
# Restarts the router once it is enrolled, when it needs it:
# compose-deploy.sh does not recreate the container for a config.yml change
# alone (same as ntfy's hook), and each start renews the router certificate
# (--extend). A restart drops every circuit through this router for ~10 s
# (Caddy's Ziti upstreams answered 502, 2026-11-08), so it no longer runs
# on every deploy: only when config.yml differs from the one the router
# was last restarted with, or the certificate expires within 30 days.
set -euo pipefail

if [ ! -s data/ugreen.cert ]; then
  echo "WARNING: router ugreen is not enrolled yet - run scripts/ziti-enroll-router.sh ugreen." >&2
  exit 0
fi

stamp=.config-restarted.sha256
want=$(sha256sum config.yml | cut -d' ' -f1)
if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ] \
  && openssl x509 -checkend $((30 * 86400)) -noout -in data/ugreen.cert >/dev/null; then
  echo "ziti-router-ugreen: config unchanged, certificate valid for 30+ days - not restarted"
  exit 0
fi
docker restart ziti-router-ugreen >/dev/null
printf '%s\n' "$want" >"$stamp"
echo "ziti-router-ugreen: restarted"
