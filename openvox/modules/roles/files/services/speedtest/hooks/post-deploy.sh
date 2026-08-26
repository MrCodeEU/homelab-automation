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

# Mesh iperf3 test scheduling + low-speed ntfy alerting, auto-provisioned via
# Netronome's own REST API (confirmed via its source: no config-as-code path
# exists via env vars/config file, only session-cookie-authenticated
# endpoints - POST /api/iperf/servers, /api/schedules,
# /api/notifications/{channels,rules}). Idempotent: every block checks the
# API for an existing match before creating, since this hook re-runs on
# every deploy.
#
# Architecturally this is nuc -> {mljr,ugreen,nas}, not a true all-pairs
# mesh: Netronome only runs as a single instance (this container, on nuc)
# and is the only process that ever execs iperf3 as a client
# (internal/speedtest/iperf.go) - agents only report host metrics, they
# never run their own scheduled tests. A real mesh would need a Netronome
# instance per host.
#
# Run in a subshell with its own errexit: a transient failure here (API not
# ready yet, a stray duplicate found by the idempotency check) must not fail
# this whole hook - speedtest is in critical_hook_services, so a hard exit
# here would block the entire deploy over what's ultimately best-effort
# alerting setup, not the service itself.
if ! (
  set -euo pipefail
  API="http://127.0.0.1:8090/api"
  COOKIEJAR=$(mktemp)
  trap 'rm -f "$COOKIEJAR"' EXIT

  curl -fsS -c "$COOKIEJAR" -X POST "$API/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u admin --arg p "$NETRONOME_ADMIN_PASSWORD" '{username:$u,password:$p}')" \
    >/dev/null
  echo "SUCCESS: Netronome API session established."

  api_get() { curl -fsS -b "$COOKIEJAR" "$API$1"; }
  api_post() { curl -fsS -b "$COOKIEJAR" -X POST "$API$1" -H 'Content-Type: application/json' -d "$2"; }

  declare -A MESH_TARGETS=([mljr]=5201 [ugreen]=5201 [nas]=5201)

  existing_servers=$(api_get "/iperf/servers")
  server_ids=()
  for host in "${!MESH_TARGETS[@]}"; do
    port="${MESH_TARGETS[$host]}"
    sid=$(echo "$existing_servers" | jq -r --arg h "$host" '.[] | select(.name==$h) | .id')
    if [ -z "$sid" ]; then
      sid=$(api_post "/iperf/servers" "$(jq -nc --arg n "$host" --arg h "$host" --argjson p "$port" '{name:$n,host:$h,port:$p}')" | jq -r '.server.id')
      echo "SUCCESS: registered iperf3 target $host:$port (id=$sid)."
    fi
    server_ids+=("$sid")
  done
  server_ids_json=$(printf '%s\n' "${server_ids[@]}" | jq -R . | jq -sc 'sort')

  existing_schedules=$(api_get "/schedules")
  has_schedule=$(echo "$existing_schedules" | jq --argjson want "$server_ids_json" \
    '[.[] | select(.options.useIperf==true and ((.serverIds|sort)==$want))] | length')
  if [ "$has_schedule" -eq 0 ]; then
    options=$(jq -nc --argjson ids "$server_ids_json" \
      '{enableDownload:true,enableUpload:true,enablePacketLoss:false,enablePing:false,enableJitter:false,serverIds:$ids,isScheduled:true,useIperf:true,useLibrespeed:false,isPublicServer:false}')
    api_post "/schedules" "$(jq -nc --argjson ids "$server_ids_json" --argjson opts "$options" \
      '{serverIds:$ids,interval:"1h",enabled:true,options:$opts}')" >/dev/null
    echo "SUCCESS: hourly mesh iperf3 schedule created (targets: ${!MESH_TARGETS[*]})."
  fi

  NTFY_URL="ntfy://ntfy.mljr.eu/netronome-alerts"
  existing_channels=$(api_get "/notifications/channels")
  channel_id=$(echo "$existing_channels" | jq -r --arg u "$NTFY_URL" '.[] | select(.url==$u) | .id')
  if [ -z "$channel_id" ]; then
    channel_id=$(api_post "/notifications/channels" \
      "$(jq -nc --arg n "Mesh speed alerts" --arg u "$NTFY_URL" '{name:$n,url:$u,enabled:true}')" | jq -r '.id')
    echo "SUCCESS: ntfy channel created (id=$channel_id)."
  fi

  existing_events=$(api_get "/notifications/events?category=speedtest")
  existing_rules=$(api_get "/notifications/rules")
  for event_type in download_low upload_low; do
    event_id=$(echo "$existing_events" | jq -r --arg t "$event_type" '.[] | select(.event_type==$t) | .id')
    if [ -z "$event_id" ]; then
      echo "WARNING: no notification event found for $event_type, skipping rule." >&2
      continue
    fi
    has_rule=$(echo "$existing_rules" | jq --argjson c "$channel_id" --argjson e "$event_id" \
      '[.[] | select(.channel_id==$c and .event_id==$e)] | length')
    if [ "$has_rule" -eq 0 ]; then
      api_post "/notifications/rules" \
        "$(jq -nc --argjson c "$channel_id" --argjson e "$event_id" \
          '{channel_id:$c,event_id:$e,enabled:true,threshold_value:20,threshold_operator:"lt"}')" >/dev/null
      echo "SUCCESS: low-speed ntfy rule created for $event_type (<20 Mbps)."
    fi
  done
); then
  echo "WARNING: mesh iperf3/alert provisioning failed (non-fatal, will retry next deploy)." >&2
fi
