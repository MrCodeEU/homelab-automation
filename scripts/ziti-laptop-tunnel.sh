#!/usr/bin/env bash
# Install the OpenZiti tunneler on this laptop and enrol it as identity
# laptop-mrcode with #admin (docs/ZERO_TRUST_PLAN.md C8). Run it yourself in
# a terminal: it uses sudo. Needs SSH to mljr.
#
#   1. on the controller, create identity laptop-mrcode (#admin) unless it
#      exists; its one-time token (valid 3 h) is piped straight into
#      /var/lib/ziti-edge-tunnel/laptop-mrcode.jwt (root, 0600)
#   2. install ziti/laptop/ziti-edge-tunnel.container as a root Quadlet,
#      (re)start ziti-edge-tunnel.service, and the SSH short-name rule
#      (ziti/laptop/ssh-int-mljr-eu.conf, C10) for this user
#   3. wait for the enrolled identity, delete the token
#   4. test: resolve alloy.nuc.int.mljr.eu and fetch its metrics over Ziti
#
# Usage: scripts/ziti-laptop-tunnel.sh [--reenroll]
#   --reenroll  recreate the identity with a new token (lost or broken local
#               identity file)
# Remote commands are built locally on purpose (constants), hence SC2029.
# shellcheck disable=SC2029
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net
NAME=laptop-mrcode
DIR=/var/lib/ziti-edge-tunnel
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET="$REPO/ziti/laptop/ziti-edge-tunnel.container"
SSH_CONF="$REPO/ziti/laptop/ssh-int-mljr-eu.conf"

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

reenroll=false
case "${1:-}" in
  '') ;;
  --reenroll) reenroll=true ;;
  *) die "usage: $0 [--reenroll]" ;;
esac

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

[ -s "$QUADLET" ] && [ -s "$SSH_CONF" ] || die "missing files under ziti/laptop/"
command -v podman >/dev/null || die "podman missing"
say "sudo for the install steps"
sudo -v

# --- 1. identity + token ----------------------------------------------------
have_local=false
sudo test -s "$DIR/$NAME.json" && have_local=true
if zcli "edge list identities 'name=\"$NAME\"' -j" | grep -q "\"name\": *\"$NAME\""; then
  if $reenroll; then
    # Policies match by attribute, so a recreated identity gets the same access.
    say "Recreating identity $NAME (#admin)"
    zcli "edge delete identity $NAME" >/dev/null
    zcli "edge create identity $NAME -a admin -o /tmp/$NAME.jwt" >/dev/null
    sudo rm -f "$DIR/$NAME.json"
    have_local=false
  elif ! $have_local; then
    die "identity $NAME exists but $DIR/$NAME.json does not; rerun with --reenroll"
  fi
else
  say "Creating identity $NAME (#admin)"
  zcli "edge create identity $NAME -a admin -o /tmp/$NAME.jwt" >/dev/null
fi

if ! $have_local; then
  say "Handing the token to the tunneler"
  sudo install -d -m 700 "$DIR"
  ssh "$CTRL_HOST" "docker exec ziti-controller sh -c 'cat /tmp/$NAME.jwt && rm -f /tmp/$NAME.jwt'" \
    | sudo tee "$DIR/$NAME.jwt" >/dev/null
  sudo chmod 600 "$DIR/$NAME.jwt"
  sudo test -s "$DIR/$NAME.jwt" || die "token handover failed"
  # The Quadlet loads the whole identity dir, and in that mode the image's
  # entrypoint does not enrol tokens: enrol here, with the same image.
  say "Enrolling $NAME"
  image=$(sed -n 's/^Image=//p' "$QUADLET")
  sudo podman run --rm --security-opt label=disable -v "$DIR:/ziti-edge-tunnel" \
    --entrypoint ziti-edge-tunnel "$image" \
    enroll --jwt "/ziti-edge-tunnel/$NAME.jwt" --identity "/ziti-edge-tunnel/$NAME.json" >/dev/null \
    || die "enrolment failed"
  sudo rm -f "$DIR/$NAME.jwt"
fi

# --- 2. Quadlet + SSH short names ---------------------------------------------
# An earlier version set int.mljr.eu as a resolved search domain; it lost
# the race against the other links' search domains (see SSH_CONF), remove it.
if [ -e /etc/systemd/resolved.conf.d/int-mljr-eu.conf ]; then
  sudo rm -f /etc/systemd/resolved.conf.d/int-mljr-eu.conf
  sudo systemctl reload systemd-resolved
fi

say "Installing the SSH short-name rule"
install -d -m 700 "$HOME/.ssh/config.d"
install -m 600 "$SSH_CONF" "$HOME/.ssh/config.d/int-mljr-eu.conf"
# Canonicalization options must come before any Host block, so the Include
# goes on the first line.
if ! grep -qxF 'Include config.d/*.conf' "$HOME/.ssh/config" 2>/dev/null; then
  { echo 'Include config.d/*.conf'; cat "$HOME/.ssh/config" 2>/dev/null || true; } > "$HOME/.ssh/config.new"
  chmod 600 "$HOME/.ssh/config.new" && mv "$HOME/.ssh/config.new" "$HOME/.ssh/config"
fi

say "Installing the Quadlet and starting ziti-edge-tunnel.service"
sudo install -m 644 "$QUADLET" /etc/containers/systemd/ziti-edge-tunnel.container
sudo systemctl daemon-reload
sudo systemctl restart ziti-edge-tunnel.service

# --- 3. wait for enrolment ----------------------------------------------------
for _ in $(seq 1 60); do
  sudo test -s "$DIR/$NAME.json" && break
  sleep 2
done
sudo rm -f "$DIR/$NAME.jwt"
sudo test -s "$DIR/$NAME.json" || die "not enrolled; check: sudo journalctl -u ziti-edge-tunnel -n 50"

# --- 4. test ------------------------------------------------------------------
say "Testing alloy.nuc.int.mljr.eu over Ziti"
# The tunneler loads its services a few seconds after start.
ok=false
for _ in $(seq 1 30); do
  if curl -sf --max-time 5 http://alloy.nuc.int.mljr.eu:12345/metrics | grep -q '^alloy_build_info'; then
    ok=true; break
  fi
  sleep 2
done
resolvectl query alloy.nuc.int.mljr.eu 2>&1 | head -2 | sed 's/^/    /'
ssh -G nuc 2>/dev/null | grep '^hostname ' | sed 's/^/    ssh nuc -> /'
$ok || die "metrics not reachable over Ziti; check: sudo journalctl -u ziti-edge-tunnel -n 50"
say "Tunneler up: alloy.nuc.int.mljr.eu:12345 answers over Ziti."
