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

if [ -z "${CROWDSEC_NUC_AGENT_PASSWORD:-}" ]; then
  echo "FAILED: CROWDSEC_NUC_AGENT_PASSWORD is empty. Set secrets.crowdsec.nuc_agent_password."
  exit 1
fi

if [ -z "${CROWDSEC_NAS_AGENT_PASSWORD:-}" ]; then
  echo "FAILED: CROWDSEC_NAS_AGENT_PASSWORD is empty. Set secrets.crowdsec.nas_agent_password."
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

# Restart only when something the running agent has not loaded changed:
# a bind-mounted config file (compose-deploy.sh does not recreate the
# container for file content alone) or the installed Hub content. A
# restart takes the LAPI and AppSec away for seconds; Caddy fails open
# meanwhile, so requests go uninspected (healthreport
# appsec_unavailable_24h, 2026-11-21: 28 per day from restarts on every
# deploy).
hub_state() { docker exec crowdsec cscli hub list -o raw | sha256sum | cut -d' ' -f1; }
hub_before=$(hub_state)
stamp=.config-restarted.sha256
want=$(find acquis.yaml profiles.yaml appsec-configs parsers -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)

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

restarted=false
if [ "$(hub_state)" != "$hub_before" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  docker restart crowdsec >/dev/null
  restarted=true
  printf '%s\n' "$want" >"$stamp"
  echo "INFO: CrowdSec config or Hub content changed - restarted."

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
else
  echo "INFO: CrowdSec config and Hub content unchanged - not restarted."
fi

docker exec crowdsec cscli bouncers delete firewall --ignore-missing >/dev/null
docker exec crowdsec cscli bouncers add firewall --key "${CROWDSEC_FIREWALL_BOUNCER_KEY}" >/dev/null
echo "SUCCESS: CrowdSec firewall bouncer API key converged."

if docker exec crowdsec cscli machines inspect crowdsec-web-ui >/dev/null 2>&1; then
  echo "SUCCESS: CrowdSec web UI machine already exists."
else
  docker exec crowdsec cscli machines add crowdsec-web-ui \
    --password "${CROWDSEC_WEB_UI_PASSWORD}" \
    -f /dev/null
  restarted=true
  echo "SUCCESS: CrowdSec web UI machine created."
fi

if docker exec crowdsec cscli machines inspect nuc >/dev/null 2>&1; then
  echo "SUCCESS: CrowdSec nuc agent machine already exists."
else
  docker exec crowdsec cscli machines add nuc \
    --password "${CROWDSEC_NUC_AGENT_PASSWORD}" \
    -f /dev/null
  echo "SUCCESS: CrowdSec nuc agent machine created."
fi

if docker exec crowdsec cscli machines inspect nas >/dev/null 2>&1; then
  echo "SUCCESS: CrowdSec nas agent machine already exists."
else
  docker exec crowdsec cscli machines add nas \
    --password "${CROWDSEC_NAS_AGENT_PASSWORD}" \
    -f /dev/null
  echo "SUCCESS: CrowdSec nas agent machine created."
fi

# The web UI reconnects to a restarted LAPI only after its own restart.
if $restarted; then
  docker restart crowdsec-web-ui >/dev/null
  echo "SUCCESS: CrowdSec web UI restarted."
fi
