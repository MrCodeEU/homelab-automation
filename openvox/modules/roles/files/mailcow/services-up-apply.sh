#!/usr/bin/env bash
# Runs on every real apply, unconditionally - `docker compose up -d` is
# itself idempotent (no recreate unless the resolved spec actually
# changed), so this doesn't need its own unless-guard the way a
# non-idempotent command would. Matches the already-validated spot
# port's own reasoning for the same host.
set -euo pipefail
cd /opt/mailcow-dockerized
docker compose up -d --remove-orphans
