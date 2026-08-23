#!/usr/bin/env bash
# Ported from the Ansible role's own wait_for(host, port, timeout=60) -
# same reasoning: give the Dockerized CrowdSec LAPI (services.pp's
# "crowdsec" catalog entry) time to come up before the bouncer package
# tries to reach it, without hardcoding a fixed sleep.
set -uo pipefail
for i in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/8088) 2>/dev/null; then
    exec 3>&- 3<&-
    exit 0
  fi
  sleep 1
done
echo "ERROR: CrowdSec LAPI not reachable on 127.0.0.1:8088 after 60s" >&2
exit 1
