#!/usr/bin/env bash
# Strips any prior-generation (Ansible or spot) backup-remote-target
# Match block plus any stale OpenVox one, appends the current OpenVox
# block, validates with sshd -t before installing, restarts sshd only on
# a real change - reload was confirmed (during the spot port) to not
# fully re-evaluate Match-block state for already-listening connections.
set -euo pipefail
CONF=/etc/ssh/sshd_config
TMP=/etc/ssh/.sshd_config.openvox-tmp

sed \
  -e '/# BEGIN ANSIBLE MANAGED BLOCK - backup-remote-target/,/# END ANSIBLE MANAGED BLOCK - backup-remote-target/d' \
  -e '/# BEGIN SPOT MANAGED BLOCK - backup-remote-target/,/# END SPOT MANAGED BLOCK - backup-remote-target/d' \
  -e '/# BEGIN OPENVOX MANAGED BLOCK - backup-remote-target/,/# END OPENVOX MANAGED BLOCK - backup-remote-target/d' \
  "$CONF" > "$TMP"

cat >> "$TMP" <<'BLOCK'
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

sshd -t -f "$TMP"
mv "$TMP" "$CONF"
systemctl restart ssh
