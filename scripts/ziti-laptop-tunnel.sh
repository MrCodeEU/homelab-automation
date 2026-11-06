#!/usr/bin/env bash
# Install the OpenZiti tunneler on this laptop and enrol it as identity
# laptop-mrcode with #admin (docs/ZERO_TRUST_PLAN.md C8). Run it yourself in
# a terminal: it uses sudo. Needs SSH to mljr.
#
#   1. on the controller, create identity laptop-mrcode (#admin) unless it
#      exists; its one-time token (valid 3 h) is piped straight into
#      /var/lib/ziti-edge-tunnel/laptop-mrcode.jwt (root, 0600)
#   2. install ziti/laptop/ziti-edge-tunnel.container as a root Quadlet and
#      (re)start ziti-edge-tunnel.service
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

[ -s "$QUADLET" ] || die "missing $QUADLET"
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
fi

# --- 2. Quadlet ---------------------------------------------------------------
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
ok=false
for _ in $(seq 1 15); do
  if curl -sf --max-time 5 http://alloy.nuc.int.mljr.eu:12345/metrics | grep -q '^alloy_build_info'; then
    ok=true; break
  fi
  sleep 2
done
resolvectl query alloy.nuc.int.mljr.eu 2>&1 | head -2 | sed 's/^/    /'
$ok || die "metrics not reachable over Ziti; check: sudo journalctl -u ziti-edge-tunnel -n 50"
say "Tunneler up: alloy.nuc.int.mljr.eu:12345 answers over Ziti."
