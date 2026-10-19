#!/usr/bin/env bash
# ExecStartPre for docker.service (see roles::base). Containers published on
# the host's tailnet IP (e.g. crowdsec's LAPI on 100.100.20.1:8088) fail
# their port bind with "cannot assign requested address" when dockerd starts
# before tailscaled has put the address on tailscale0. `restart: unless-stopped`
# does not retry a failed network setup, so the container stays down until
# someone starts it by hand (2026-10-18 reboot: crowdsec down ~23h).
#
# Waits up to ~2 min, then exits 0 regardless - a missing tailnet must never
# keep Docker (and every other service) from starting.
IP="${1:?usage: wait-tailscale-ip.sh <tailscale-ip>}"
for _ in $(seq 1 60); do
  if /usr/sbin/ip -4 -o addr show dev tailscale0 2>/dev/null | grep -q "inet ${IP}/"; then
    exit 0
  fi
  sleep 2
done
echo "wait-tailscale-ip: ${IP} not on tailscale0 after 120s, starting docker anyway" >&2
exit 0
