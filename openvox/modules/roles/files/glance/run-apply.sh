#!/usr/bin/env bash
# Unconditional force-remove + recreate on every apply - ported
# faithfully from the Ansible role's own docker_container module usage,
# which has no idempotency guard here either. See roles::glance's class
# doc for why this is deliberate, not an oversight.
set -euo pipefail
docker rm -f glance >/dev/null 2>&1 || true
docker pull glanceapp/glance
docker run -d \
  --name glance \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v /opt/glance/config:/app/config \
  -v /etc/timezone:/etc/timezone:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  glanceapp/glance
