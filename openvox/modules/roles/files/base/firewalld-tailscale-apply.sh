#!/usr/bin/env bash
# Adds the Tailscale CIDR to the trusted zone without touching any other
# source already present (e.g. nuc's own separate LAN source) - matches
# ansible.posix.firewalld's own additive state:enabled semantics.
set -euo pipefail
firewall-cmd --zone=trusted --add-source=100.64.0.0/10 --permanent
firewall-cmd --zone=trusted --add-source=100.64.0.0/10
