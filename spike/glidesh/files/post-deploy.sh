#!/bin/bash
# Waits for the new container, then records the deploy.
set -euo pipefail
for _ in $(seq 30); do
  if curl -fsS http://127.0.0.1:8080/ | grep -q '^Name: '; then
    date -u +%FT%TZ > /opt/whoami/last-deploy
    exit 0
  fi
  sleep 1
done
echo 'whoami did not answer' >&2
exit 1
