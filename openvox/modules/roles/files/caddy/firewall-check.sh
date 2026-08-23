#!/usr/bin/env bash
set -uo pipefail
systemctl is-active --quiet firewalld || exit 1
firewall-cmd --list-services 2>/dev/null | grep -qw http || exit 1
firewall-cmd --list-services 2>/dev/null | grep -qw https || exit 1
firewall-cmd --list-ports 2>/dev/null | grep -qw "443/udp" || exit 1
exit 0
