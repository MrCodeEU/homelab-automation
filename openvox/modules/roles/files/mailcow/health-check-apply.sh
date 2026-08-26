#!/usr/bin/env bash
# Non-blocking - never fails the apply, matches the Ansible role's own
# failed_when: false (mailcow can be slow to become ready).
set -euo pipefail
for _ in 1 2 3; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${MAILCOW_HTTP_PORT}" || echo "000")
  case "$code" in
    200|301|302) exit 0 ;;
  esac
  sleep 3
done
echo "WARNING: mailcow nginx did not respond with 200/301/302 on 127.0.0.1:${MAILCOW_HTTP_PORT} (non-blocking)" >&2
