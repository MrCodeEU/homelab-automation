#!/usr/bin/env bash
set -euo pipefail

if [ -z "${CROWDSEC_WEB_UI_PASSWORD:-}" ]; then
  echo "FAILED: CROWDSEC_WEB_UI_PASSWORD is empty. Set secrets.crowdsec.web_ui_password."
  exit 1
fi

if [ -z "${CROWDSEC_FIREWALL_BOUNCER_KEY:-}" ]; then
  echo "FAILED: CROWDSEC_FIREWALL_BOUNCER_KEY is empty. Set secrets.crowdsec.firewall_bouncer_key."
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

echo "INFO: Updating CrowdSec Hub index."
docker exec crowdsec cscli hub update

STRICT_SCENARIOS=(
  "crowdsecurity/http-dos-random-uri"
  "crowdsecurity/http-dos-switching-ua"
  "crowdsecurity/http-dos-invalid-http-versions"
  "crowdsecurity/http-dos-bypass-cache"
  "crowdsecurity/http-wordpress_user-enum"
  "crowdsecurity/http-wordpress_wpconfig"
  "ltsich/http-w00tw00t"
)

for scenario in "${STRICT_SCENARIOS[@]}"; do
  if docker exec crowdsec cscli scenarios inspect "${scenario}" >/dev/null 2>&1; then
    echo "SUCCESS: CrowdSec scenario ${scenario} already installed."
  else
    docker exec crowdsec cscli scenarios install "${scenario}"
    echo "SUCCESS: CrowdSec scenario ${scenario} installed."
  fi
done

echo "INFO: Upgrading installed CrowdSec Hub content."
docker exec crowdsec cscli hub upgrade

docker restart crowdsec >/dev/null

for attempt in $(seq 1 30); do
  if docker exec crowdsec cscli lapi status >/dev/null 2>&1; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: CrowdSec Local API did not become ready after Hub maintenance."
    exit 1
  fi

  sleep 2
done

docker exec crowdsec cscli bouncers delete firewall --ignore-missing >/dev/null
docker exec crowdsec cscli bouncers add firewall --key "${CROWDSEC_FIREWALL_BOUNCER_KEY}" >/dev/null
echo "SUCCESS: CrowdSec firewall bouncer API key converged."

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
