#!/usr/bin/env bash
# Read-only guard for custom-binary-apply.sh: exit 0 when the custom Caddy
# binary is installed, matches the pinned SHA-256 and carries the right
# SELinux type. Env: CADDY_CUSTOM_BIN, CADDY_CUSTOM_SHA256.
set -uo pipefail
bin=${CADDY_CUSTOM_BIN:?}
want=${CADDY_CUSTOM_SHA256:?}
[ -x "$bin" ] || exit 1
[ "$(sha256sum "$bin" | cut -d' ' -f1)" = "$want" ] || exit 1
ls -Z "$bin" 2>/dev/null | grep -q httpd_exec_t || exit 1
exit 0
