#!/usr/bin/env bash
# Exits 0 (no work needed) if the staged config already matches live.
set -uo pipefail
diff -rq /etc/caddy/conf.d.openvox-staging /etc/caddy/conf.d --exclude='.services-checksum' >/dev/null 2>&1 || exit 1
cmp -s /etc/caddy/Caddyfile.openvox-staging /etc/caddy/Caddyfile 2>/dev/null || exit 1
exit 0
