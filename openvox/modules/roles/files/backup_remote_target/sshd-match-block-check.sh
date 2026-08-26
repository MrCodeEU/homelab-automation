#!/usr/bin/env bash
# unless-guard for backup-remote-target-sshd-match-block: exits 0 (skip
# the apply script) only if the OpenVox-managed block is present verbatim
# AND no leftover Ansible/spot-generation block remains alongside it.
set -euo pipefail
CONF=/etc/ssh/sshd_config

if grep -qF "BEGIN ANSIBLE MANAGED BLOCK - backup-remote-target" "$CONF" 2>/dev/null; then
  exit 1
fi
if grep -qF "BEGIN SPOT MANAGED BLOCK - backup-remote-target" "$CONF" 2>/dev/null; then
  exit 1
fi

expected=$(cat <<'BLOCK'
# BEGIN OPENVOX MANAGED BLOCK - backup-remote-target
Match User rclone-backup
  ChrootDirectory /volume1/homelab-backups
  ForceCommand internal-sftp
  AllowTcpForwarding no
  AllowAgentForwarding no
  X11Forwarding no
  PermitTTY no
  PasswordAuthentication no
# END OPENVOX MANAGED BLOCK - backup-remote-target
BLOCK
)

current=$(sed -n '/# BEGIN OPENVOX MANAGED BLOCK - backup-remote-target/,/# END OPENVOX MANAGED BLOCK - backup-remote-target/p' "$CONF")
[ "$current" = "$expected" ]
