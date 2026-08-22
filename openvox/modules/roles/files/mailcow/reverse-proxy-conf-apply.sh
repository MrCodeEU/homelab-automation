#!/usr/bin/env bash
# HTTP_PORT=8092 (not 8081) is load-bearing - 8081 collides with
# mailcow's own hardcoded internal rspamd dynmaps nginx vhost regardless
# of this setting, confirmed live 2026-08-14 (see roles::mailcow's class
# doc). Never lower this below what roles::mailcow passes in.
set -euo pipefail
CONF=/opt/mailcow-dockerized/mailcow.conf
set_kv() {
  key="$1"; value="$2"
  if grep -q "^${key}=" "$CONF"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONF"
  else
    echo "${key}=${value}" >> "$CONF"
  fi
}
set_kv HTTP_PORT "${MAILCOW_HTTP_PORT}"
set_kv HTTP_BIND "${MAILCOW_HTTP_BIND}"
set_kv HTTPS_PORT "${MAILCOW_HTTPS_PORT}"
set_kv HTTPS_BIND "${MAILCOW_HTTP_BIND}"
set_kv SKIP_LETS_ENCRYPT y
set_kv SKIP_HTTP_VERIFICATION y
set_kv SKIP_CLAMD "${MAILCOW_SKIP_CLAMD}"
set_kv SNAT_TO_SOURCE ""
