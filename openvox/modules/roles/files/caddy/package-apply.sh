#!/usr/bin/env bash
set -euo pipefail
dnf install -y 'dnf-command(copr)'
dnf copr enable -y @caddy/caddy
COPR_REPO="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:group_caddy:caddy.repo"
if [ -f "$COPR_REPO" ]; then
  crudini --set "$COPR_REPO" "copr:copr.fedorainfracloud.org:group_caddy:caddy" priority 1 2>/dev/null || \
    sed -i '/^\[copr:copr.fedorainfracloud.org:group_caddy:caddy\]/,/^\[/ s/^priority=.*/priority=1/' "$COPR_REPO"
fi
dnf install -y caddy
echo "caddy installed/updated"
