#!/usr/bin/env bash
set -uo pipefail
systemctl is-active --quiet caddy || exit 1
systemctl is-enabled --quiet caddy || exit 1
exit 0
