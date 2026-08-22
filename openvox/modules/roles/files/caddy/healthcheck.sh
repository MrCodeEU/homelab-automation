#!/usr/bin/env bash
# Read-only health check, always runs regardless of noop - never mutates
# anything, it just proves the end result works.
set -uo pipefail
for i in 1 2 3 4 5; do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "https://deploy.mljr.eu" 2>/dev/null || echo "000")
  case "$code" in
    200|301|302) echo "caddy is serving requests"; exit 0 ;;
  esac
  sleep 2
done
echo "WARNING: caddy is not serving https requests on deploy.mljr.eu (non-blocking)" >&2
ss -tlnp 2>/dev/null | grep caddy || echo "no caddy process listening" >&2
