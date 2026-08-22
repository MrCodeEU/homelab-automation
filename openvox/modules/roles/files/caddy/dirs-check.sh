#!/usr/bin/env bash
# /var/log/caddy's real steady-state mode reads 2775, not 2755 - the
# setfacl mask below (m:rwx) gets folded into stat's reported mode bits
# alongside the literal 2755 install -d sets. Confirmed live on the
# already-validated spot port.
set -uo pipefail
[ -d /opt/caddy/site ] || exit 1
[ -d /etc/caddy/conf.d ] || exit 1
[ -d /var/log/caddy ] || exit 1
[ "$(stat -c '%a' /var/log/caddy 2>/dev/null)" = "2775" ]
