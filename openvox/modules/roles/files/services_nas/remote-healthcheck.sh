#!/usr/bin/env bash
# Read-only health probe against a nas-hosted service, run directly from
# nuc (no SSH needed - both hosts are on the same tailnet, this is a
# plain network request). Args: $1 = service name, $2 = host (nas's own
# tailscale IP), $3 = port. Same non-blocking shape as healthcheck.sh's
# rocky/ugreen sibling.
set -uo pipefail
name="$1"
host="$2"
port="$3"
code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${host}:${port}" 2>/dev/null || echo "000")
case "$code" in
  200|301|302|400|401|403) echo "${name}: HEALTHY (${code})"; exit 0 ;;
esac
echo "WARNING: ${name} not responding on ${host}:${port} (got ${code}, non-blocking)" >&2
