#!/usr/bin/env bash
# Read-only health probe against a nas-hosted service: curl on nas itself
# against loopback, over nuc's management key (`ssh nas-mgmt`,
# roles::nas_mgmt_key). The services publish on 127.0.0.1 (or, like Photon,
# on docker0), not on an address nuc could reach directly.
# Args: $1 = service name, $2 = port. Same non-blocking shape as
# healthcheck.sh's rocky/ugreen sibling.
set -uo pipefail
name="$1"
port="$2"
case "$name" in photon) host=172.17.0.1 ;; *) host=127.0.0.1 ;; esac
code=$(ssh -o BatchMode=yes nas-mgmt "curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 http://${host}:${port}" 2>/dev/null || echo "000")
case "$code" in
  200|301|302|307|308|400|401|403) echo "${name}: HEALTHY (${code})"; exit 0 ;;
esac
echo "WARNING: ${name} not responding on nas ${host}:${port} (got ${code}, non-blocking)" >&2
