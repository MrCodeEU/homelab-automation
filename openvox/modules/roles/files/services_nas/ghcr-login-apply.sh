#!/usr/bin/env bash
# GHCR login on nas, run via SSH from nuc (proxy-exec - nas has no real
# Puppet agent). CLI-based, not community.docker.docker_login, matching
# Ansible's own Unraid branch: Unraid has no docker Python SDK. DOCKER_CONFIG
# points at the array (/mnt/user/appdata/homelab/.docker, not /root/.docker)
# because Unraid's root filesystem is tmpfs - roles::unraid_proxy's bootstrap
# script re-links it into place at array start so credentials survive a
# reboot. Best-effort, matches ghcr-login-apply.sh's own rocky/ugreen sibling:
# never blocks the rest of the apply.
set -uo pipefail
TARGET="root@nas.tail33930.ts.net"
BASE=/mnt/user/appdata/homelab

if [ -z "${GHCR_USER:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
  exit 0
fi

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "DOCKER_CONFIG=${BASE}/.docker docker login ghcr.io --username '${GHCR_USER}' --password-stdin" \
  <<< "$GHCR_TOKEN" || true
