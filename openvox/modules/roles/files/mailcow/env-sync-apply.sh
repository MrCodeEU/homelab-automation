#!/usr/bin/env bash
# Docker Compose reads .env for variable substitution - mailcow.conf is
# the real source of truth, this just mirrors it.
set -euo pipefail
cp /opt/mailcow-dockerized/mailcow.conf /opt/mailcow-dockerized/.env
chmod 600 /opt/mailcow-dockerized/.env
