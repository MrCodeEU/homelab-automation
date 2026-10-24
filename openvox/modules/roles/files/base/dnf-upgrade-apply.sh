#!/usr/bin/env bash
# Always runs on every apply, same as the Ansible role's own
# `dnf: name=* state=latest` - dnf itself is what's idempotent here (a
# no-op transaction when everything is already current), not this exec.
#
# tailscale is excluded and upgraded separately: its package scriptlet
# restarts tailscaled, which kills the Tailscale-SSH session the apply runs
# over and aborts the catalog half way (2026-10-22, nuc). The deferred upgrade
# runs as a transient systemd timer, so it neither depends on that session
# nor races the rest of this apply.
set -euo pipefail
dnf install -y epel-release
dnf upgrade -y --refresh --exclude='tailscale*'

rpm -q tailscale >/dev/null 2>&1 || exit 0
systemctl is-active --quiet homelab-tailscale-upgrade.timer && exit 0
systemctl is-active --quiet homelab-tailscale-upgrade.service && exit 0

# dnf check-update: exit 100 = updates available, 0 = none, 1 = error.
rc=0
dnf -q check-update tailscale >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 100 ]; then
  systemd-run --quiet --unit=homelab-tailscale-upgrade --on-active=15min \
    /usr/bin/dnf upgrade -y tailscale
fi
