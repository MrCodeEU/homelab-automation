#!/usr/bin/env bash
set -euo pipefail

if [ -z "${CROWDSEC_WEB_UI_PASSWORD:-}" ]; then
  echo "FAILED: CROWDSEC_WEB_UI_PASSWORD is empty. Set secrets.crowdsec.web_ui_password."
  exit 1
fi

for attempt in $(seq 1 30); do
  if docker exec crowdsec cscli lapi status >/dev/null 2>&1; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: CrowdSec Local API did not become ready."
    exit 1
  fi

  sleep 2
done

if docker exec crowdsec cscli machines inspect crowdsec-web-ui >/dev/null 2>&1; then
  echo "SUCCESS: CrowdSec web UI machine already exists."
else
  docker exec crowdsec cscli machines add crowdsec-web-ui \
    --password "${CROWDSEC_WEB_UI_PASSWORD}" \
    -f /dev/null
  echo "SUCCESS: CrowdSec web UI machine created."
fi

docker restart crowdsec-web-ui >/dev/null
echo "SUCCESS: CrowdSec web UI restarted."
