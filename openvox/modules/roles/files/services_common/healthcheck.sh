#!/usr/bin/env bash
# Read-only, non-blocking health probe. Args: $1 = service name, $2 = port.
set -uo pipefail
name="$1"
port="$2"
code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}" 2>/dev/null || echo "000")
case "$code" in
  200|301|302|400|401|403) echo "${name}: HEALTHY (${code})"; exit 0 ;;
esac
echo "WARNING: ${name} not responding on port ${port} (got ${code}, non-blocking)" >&2
