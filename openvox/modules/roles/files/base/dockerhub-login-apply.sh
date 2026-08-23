#!/usr/bin/env bash
# Always re-runs when credentials are present, same as the Ansible role's
# reauthorize: true - `docker login` is cheap/idempotent by itself, no
# unless check needed. Skips silently if either credential is empty,
# matching the Ansible task's own `when` guard.
set -euo pipefail
if [ -z "${DOCKERHUB_USER:-}" ] || [ -z "${DOCKERHUB_PASS:-}" ]; then
  exit 0
fi
echo "${DOCKERHUB_PASS}" | docker login --username "${DOCKERHUB_USER}" --password-stdin https://index.docker.io/v1/
