#!/usr/bin/env bash
set -euo pipefail

if [ -z "${NETRONOME_ADMIN_PASSWORD:-}" ]; then
  echo "FAILED: NETRONOME_ADMIN_PASSWORD is empty. Set secrets.netronome.admin_password."
  exit 1
fi

for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8090/ >/dev/null 2>&1; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: Netronome did not become ready."
    exit 1
  fi

  sleep 2
done

if printf '%s\n' "${NETRONOME_ADMIN_PASSWORD}" | docker exec -i speedtest netronome change-password admin >/dev/null 2>&1; then
  echo "SUCCESS: Netronome admin password updated."
else
  printf '%s\n' "${NETRONOME_ADMIN_PASSWORD}" | docker exec -i speedtest netronome create-user admin >/dev/null
  echo "SUCCESS: Netronome admin user created."
fi
