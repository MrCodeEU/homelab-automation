#!/usr/bin/env bash
set -euo pipefail
grep -qxF "ListenAddress ${TAILSCALE_IP}:22" /etc/ssh/sshd_config
grep -qxF "ListenAddress 127.0.0.1:22" /etc/ssh/sshd_config
grep -qxF "ListenAddress ${PUBLIC_IP}:${BREAKGLASS_PORT}" /etc/ssh/sshd_config
