#!/usr/bin/env bash
set -euo pipefail

# compose-deploy.sh does not recreate a container for a bind-mounted file
# change, so a loki.yml edit alone never reaches Loki. Restart it when
# loki.yml differs from the one it was last restarted with (stamp, as in the
# ntfy hook), not on every deploy.
stamp=.loki-config-restarted.sha256
want=$(sha256sum loki/loki.yml | cut -d" " -f1)
if [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  docker restart loki >/dev/null
  printf "%s\n" "$want" >"$stamp"
  echo "loki: loki.yml changed - restarted"
else
  echo "loki: loki.yml unchanged - not restarted"
fi

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

# KEEP IN SYNC with provisioning/datasources/datasources.yml — this hook
# re-creates the datasources via API on every deploy and therefore wins
# over file provisioning. VictoriaMetrics replaced Prometheus (PromQL-
# compatible); name/uid stay "prometheus" so dashboards are untouched.
create_datasource '{
  "name": "Prometheus",
  "uid": "prometheus",
  "type": "prometheus",
  "access": "proxy",
  "url": "http://victoriametrics:8428",
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

# Alert rules, contact points and the notification policy are file-provisioned
# (provisioning/alerting/), but Grafana reads them only at startup. Reload so a
# changed file applies without a container restart.
curl -fsS -u "${GRAFANA_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -X POST "${GRAFANA_URL}/api/admin/provisioning/alerting/reload" >/dev/null
echo "SUCCESS: Grafana alerting provisioning reloaded."
