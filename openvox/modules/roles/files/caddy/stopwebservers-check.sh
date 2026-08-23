#!/usr/bin/env bash
# Exits 0 (no work needed) if none of the conflicting web servers are
# active or enabled.
set -uo pipefail
for svc in httpd nginx apache2; do
  systemctl is-active --quiet "$svc" 2>/dev/null && exit 1
  systemctl is-enabled --quiet "$svc" 2>/dev/null && exit 1
done
exit 0
