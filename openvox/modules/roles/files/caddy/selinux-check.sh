#!/usr/bin/env bash
set -uo pipefail
[ "$(getenforce 2>/dev/null)" = "Enforcing" ] || exit 0
semodule -l 2>/dev/null | grep -qx caddy_logrotate || exit 1
semanage fcontext -l 2>/dev/null | grep -q "/var/log/caddy(/.*)?.*httpd_log_t" || exit 1
exit 0
