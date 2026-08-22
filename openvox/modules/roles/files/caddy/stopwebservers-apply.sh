#!/usr/bin/env bash
set -uo pipefail
for svc in httpd nginx apache2; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
echo "conflicting web servers stopped"
