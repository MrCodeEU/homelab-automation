#!/usr/bin/env bash
set -uo pipefail
docker rm -f caddy >/dev/null 2>&1 || true
echo "legacy caddy docker container removed"
