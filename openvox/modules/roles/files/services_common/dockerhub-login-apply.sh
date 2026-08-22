#!/usr/bin/env bash
# Same pattern as roles::mailcow's dockerhub-login-apply.sh - best-effort,
# only attempted if credentials are configured, never blocks the rest of
# the apply.
set -euo pipefail
if [ -z "${DOCKERHUB_USER:-}" ] || [ -z "${DOCKERHUB_PASS:-}" ]; then
  exit 0
fi
echo "${DOCKERHUB_PASS}" | docker login --username "${DOCKERHUB_USER}" --password-stdin https://index.docker.io/v1/ || true
