#!/bin/bash
# Runs ON nas: opkssh for sshd, from the files roles::nas_opkssh staged in
# $BASE. Same result as roles::opkssh on the agent hosts. Unraid's root is
# tmpfs, so the user, the binary and /etc/opk are recreated from $BASE at
# every boot (bootstrap-content.sh) and on every change (apply.sh).
#
# sshd: Unraid has no sshd_config.d. rc.sshd copies /boot/config/ssh/* to
# /etc/ssh at boot and only rewrites ListenAddress/Port, so the two lines go
# into both copies, after AuthorizedKeysFile (before limetech's Match
# block). Until the array is up, /usr/local/bin/opkssh is missing and sshd
# skips the command; the authorized_keys files work as before.
#
# Usage: setup.sh [--check]   --check: exit 0 if everything is in place
set -euo pipefail
BASE=/mnt/user/appdata/homelab/opkssh
BIN=/usr/local/bin/opkssh
CACHE=/var/cache/opkssh
MARK='# opkssh (OpenVox roles::nas_opkssh)'
CMD='AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t'
CMD_USER='AuthorizedKeysCommandUser opksshuser'
CONFIGS=(/boot/config/ssh/sshd_config /etc/ssh/sshd_config)
FILES=(providers auth_id config.yml)

owned() { [ "$(stat -c '%U:%G %a' "$1" 2>/dev/null)" = "$2" ]; }
has_lines() { grep -qxF "$CMD" "$1" && grep -qxF "$CMD_USER" "$1"; }

in_place() {
  getent group opksshuser >/dev/null && getent passwd opksshuser >/dev/null || return 1
  cmp -s "$BASE/opkssh" "$BIN" && owned "$BIN" 'root:opksshuser 755' || return 1
  for f in "${FILES[@]}"; do
    cmp -s "$BASE/etc/$f" "/etc/opk/$f" && owned "/etc/opk/$f" 'root:opksshuser 640' || return 1
  done
  owned "$CACHE" 'opksshuser:opksshuser 700' || return 1
  for c in "${CONFIGS[@]}"; do has_lines "$c" || return 1; done
  sshd -T 2>/dev/null | grep -qx 'authorizedkeyscommand /usr/local/bin/opkssh verify %u %k %t'
}

if [ "${1:-}" = --check ]; then
  in_place
  exit
fi

getent group opksshuser >/dev/null || groupadd -r opksshuser
getent passwd opksshuser >/dev/null \
  || useradd -r -g opksshuser -s /bin/false -d /nonexistent -M opksshuser
install -m 0755 -o root -g opksshuser "$BASE/opkssh" "$BIN"
install -d -m 0750 -o root -g opksshuser /etc/opk /etc/opk/policy.d
for f in "${FILES[@]}"; do
  install -m 0640 -o root -g opksshuser "$BASE/etc/$f" "/etc/opk/$f"
done
install -d -m 0700 -o opksshuser -g opksshuser "$CACHE"

changed=false
for c in "${CONFIGS[@]}"; do
  has_lines "$c" && continue
  awk -v mark="$MARK" -v cmd="$CMD" -v user="$CMD_USER" '
    $0 == mark || $0 == cmd || $0 == user { next }
    { print }
    /^AuthorizedKeysFile/ { print mark; print cmd; print user }
  ' "$c" >"$c.openvox-tmp"
  has_lines "$c.openvox-tmp" || { rm -f "$c.openvox-tmp"; echo "no AuthorizedKeysFile line in $c" >&2; exit 1; }
  chmod --reference="$c" "$c.openvox-tmp" 2>/dev/null || true
  mv "$c.openvox-tmp" "$c"
  changed=true
done

if $changed || ! sshd -T 2>/dev/null | grep -qx 'authorizedkeyscommand /usr/local/bin/opkssh verify %u %k %t'; then
  sshd -t
  /etc/rc.d/rc.sshd reload
fi
echo "opkssh in place on nas"
