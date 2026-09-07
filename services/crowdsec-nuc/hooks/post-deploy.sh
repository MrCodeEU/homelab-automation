#!/usr/bin/env bash
set -euo pipefail

if [ -z "${CROWDSEC_AGENT_USERNAME:-}" ] || [ -z "${CROWDSEC_AGENT_PASSWORD:-}" ]; then
  echo "FAILED: CROWDSEC_AGENT_USERNAME/CROWDSEC_AGENT_PASSWORD is empty."
  exit 1
fi

echo "INFO: Updating CrowdSec Hub index."
docker exec crowdsec-nuc cscli hub update

echo "INFO: Upgrading installed CrowdSec Hub content."
docker exec crowdsec-nuc cscli hub upgrade

for attempt in $(seq 1 30); do
  if docker exec crowdsec-nuc cscli lapi status >/dev/null 2>&1; then
    echo "SUCCESS: crowdsec-nuc agent registered with mljr's LAPI."
    exit 0
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "FAILED: crowdsec-nuc agent did not register with mljr's LAPI. Check that mljr's crowdsec has a matching 'nuc' machine (see services/crowdsec/hooks/post-deploy.sh)."
    exit 1
  fi

  sleep 2
done
