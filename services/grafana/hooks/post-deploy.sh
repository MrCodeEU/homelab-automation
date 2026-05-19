#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="http://127.0.0.1:3000"
GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"

if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  echo "FAILED: GRAFANA_ADMIN_PASSWORD is empty."
  exit 1
fi

for attempt in $(seq 1 30); do
  if curl -fsS -u "${GRAFANA_USER}:${GRAFANA_ADMIN_PASSWORD}" "${GRAFANA_URL}/api/health" >/dev/null; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: Grafana API did not become ready."
    exit 1
  fi

  sleep 2
done

delete_datasource() {
  local name="$1"
  local encoded_name
  encoded_name="$(printf '%s' "$name" | sed 's/ /%20/g')"

  curl -fsS -u "${GRAFANA_USER}:${GRAFANA_ADMIN_PASSWORD}" \
    -X DELETE "${GRAFANA_URL}/api/datasources/name/${encoded_name}" >/dev/null 2>&1 || true
}

create_datasource() {
  local payload="$1"

  curl -fsS -u "${GRAFANA_USER}:${GRAFANA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${payload}" \
    "${GRAFANA_URL}/api/datasources" >/dev/null
}

delete_datasource "Prometheus"
delete_datasource "Loki"

create_datasource '{
  "name": "Prometheus",
  "uid": "prometheus",
  "type": "prometheus",
  "access": "proxy",
  "url": "http://prometheus:9090",
  "isDefault": true
}'

create_datasource '{
  "name": "Loki",
  "uid": "loki",
  "type": "loki",
  "access": "proxy",
  "url": "http://loki:3100"
}'

echo "SUCCESS: Grafana datasources converged to stable UIDs."
