#!/usr/bin/env bash
# The managed block must hold exactly these lines, so a line that was
# dropped from ssh-breakglass-apply.sh (the tailnet ListenAddress, 2026-11)
# also makes the apply run and remove it.
set -euo pipefail
want=$(printf '%s\n' \
  "ListenAddress 127.0.0.1:22" \
  "ListenAddress ${PUBLIC_IP}:${BREAKGLASS_PORT}")
have=$(sed -n '/^# BEGIN OPENVOX MANAGED BLOCK - ssh honeypot cutover$/,/^# END OPENVOX MANAGED BLOCK - ssh honeypot cutover$/{/^# \(BEGIN\|END\) OPENVOX/d;p}' /etc/ssh/sshd_config)
[ "$have" = "$want" ]
