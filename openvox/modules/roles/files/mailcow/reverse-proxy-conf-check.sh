#!/usr/bin/env bash
set -euo pipefail
CONF=/opt/mailcow-dockerized/mailcow.conf
check_kv() {
  key="$1"; value="$2"
  current=$(grep "^${key}=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-)
  [ "$current" = "$value" ]
}
check_kv HTTP_PORT "${MAILCOW_HTTP_PORT}"
check_kv HTTP_BIND "${MAILCOW_HTTP_BIND}"
check_kv HTTPS_PORT "${MAILCOW_HTTPS_PORT}"
check_kv HTTPS_BIND "${MAILCOW_HTTP_BIND}"
check_kv SKIP_LETS_ENCRYPT y
check_kv SKIP_HTTP_VERIFICATION y
check_kv SKIP_CLAMD "${MAILCOW_SKIP_CLAMD}"
check_kv SNAT_TO_SOURCE ""
