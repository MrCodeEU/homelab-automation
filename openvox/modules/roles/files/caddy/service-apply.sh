#!/usr/bin/env bash
set -euo pipefail
if ! systemctl enable --now caddy; then
  systemctl status caddy.service --no-pager || true
  journalctl -xeu caddy.service -n 50 --no-pager || true
  echo "FAILED: caddy did not start" >&2
  exit 1
fi
echo "caddy started/enabled"
