#!/usr/bin/env bash
# CrowdSec + the nftables bouncer replaced fail2ban.
#
# DANGER: do not replace the removal with a plain `dnf remove`. dnf.conf
# sets clean_requirements_on_remove=True, so removing fail2ban alone would
# also take firewalld, firewalld-filesystem, python3-firewall, ipset and
# python3-nftables with it as "unused dependencies" - firewalld is active
# and owns a live nftables table, dropping it would drop the firewall.
# --noautoremove keeps the transaction to the fail2ban packages themselves.
set -euo pipefail

systemctl stop fail2ban 2>/dev/null || true
systemctl disable fail2ban 2>/dev/null || true

pkgs=$(rpm -qa 'fail2ban*' --qf '%{NAME}\n')
if [ -n "$pkgs" ]; then
  # shellcheck disable=SC2086
  dnf remove -y --noautoremove $pkgs
  rpm -q firewalld >/dev/null || {
    echo "ERROR: firewalld did not survive fail2ban removal" >&2
    exit 1
  }
fi

systemctl reset-failed fail2ban.service 2>/dev/null || true
rm -rf /etc/fail2ban
