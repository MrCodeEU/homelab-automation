#!/usr/bin/env bash
# Glance moved from a docker-compose stack to a raw `docker run` -
# tears down the old compose project if it's still around.
set -euo pipefail
if [ -f /opt/glance/docker-compose.yml ]; then
  (cd /opt/glance && docker compose down) || true
  rm -f /opt/glance/docker-compose.yml
fi
