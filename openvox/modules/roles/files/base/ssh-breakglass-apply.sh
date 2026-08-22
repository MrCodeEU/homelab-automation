#!/usr/bin/env bash
# Scopes real sshd to Tailscale+loopback, frees the public interface's
# port 22 for a tarpit, keeps a break-glass port reachable directly in
# case Tailscale itself is ever down.
set -euo pipefail
MARKER_BEGIN="# BEGIN OPENVOX MANAGED BLOCK - ssh honeypot cutover"
MARKER_END="# END OPENVOX MANAGED BLOCK - ssh honeypot cutover"
CONF=/etc/ssh/sshd_config
TMP=$(mktemp)

# Drop any existing managed block (this generation's marker, or the older
# Ansible-generation one it may be replacing) before re-inserting it fresh.
sed '/# BEGIN \(OPENVOX\|ANSIBLE\) MANAGED BLOCK - ssh honeypot cutover/,/# END \(OPENVOX\|ANSIBLE\) MANAGED BLOCK - ssh honeypot cutover/d' "$CONF" > "$TMP"

{
  cat "$TMP"
  echo "$MARKER_BEGIN"
  echo "ListenAddress ${TAILSCALE_IP}:22"
  echo "ListenAddress 127.0.0.1:22"
  echo "ListenAddress ${PUBLIC_IP}:${BREAKGLASS_PORT}"
  echo "$MARKER_END"
} > "${CONF}.new"

/usr/sbin/sshd -t -f "${CONF}.new"
mv "${CONF}.new" "$CONF"
rm -f "$TMP"
systemctl reload sshd
