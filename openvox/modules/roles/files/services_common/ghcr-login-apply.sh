#!/usr/bin/env bash
# Mirrors ansible/roles/services' GHCR login task: logout first to clear
# stale credentials, then log in with the vault PAT. Best-effort, never
# blocks the rest of the apply.
set -euo pipefail
if [ -z "${GHCR_USER:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
  exit 0
fi
docker logout ghcr.io >/dev/null 2>&1 || true
echo "${GHCR_TOKEN}" | docker login ghcr.io --username "${GHCR_USER}" --password-stdin || true
