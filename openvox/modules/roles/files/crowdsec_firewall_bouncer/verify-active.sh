#!/usr/bin/env bash
# Ported from the Ansible role's own retry/rescue block (30 retries,
# 5s delay = 150s ceiling) - on failure dumps status+journal to stderr
# before failing the apply, same diagnostic shape.
set -uo pipefail
for _ in $(seq 1 30); do
  state=$(systemctl show crowdsec-firewall-bouncer --property=ActiveState --value)
  [ "$state" = "active" ] && exit 0
  sleep 5
done
echo "ERROR: crowdsec-firewall-bouncer did not become active after 150s" >&2
systemctl status crowdsec-firewall-bouncer --no-pager --full >&2 || true
journalctl -u crowdsec-firewall-bouncer -n 80 --no-pager >&2 || true
exit 1
