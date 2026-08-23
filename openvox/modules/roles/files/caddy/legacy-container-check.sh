#!/usr/bin/env bash
set -uo pipefail
! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx caddy
