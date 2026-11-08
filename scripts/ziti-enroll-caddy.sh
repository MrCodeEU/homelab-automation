#!/usr/bin/env bash
# Enrol mljr's Caddy as Ziti identity caddy-mljr (ziti/tofu/caddy.tf) into
# /etc/caddy/ziti/caddy-mljr.json, which the ziti reverse_proxy transport
# reads (services/caddy-poc/ziti-caddy). The identity itself is created by
# OpenTofu (scripts/ziti-tofu.sh apply); this only turns its one-time token
# into a certificate and key.
#
# Enrolment runs in the controller container on mljr, the same host as
# Caddy, so the private key never leaves mljr. The file is root:caddy 0640.
#
# Usage: scripts/ziti-enroll-caddy.sh [--reenroll]
#   --reenroll  replace an existing enrolment (lost or broken file): drops
#               the identity's certificate authenticator, issues a new token
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net
NAME=caddy-mljr
DEST=/etc/caddy/ziti/$NAME.json

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

reenroll=false
case "${1:-}" in
  "") ;;
  --reenroll) reenroll=true ;;
  *) die "usage: $0 [--reenroll]" ;;
esac

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

id=$(zcli "edge list identities 'name=\"$NAME\"' -j" | jq -r '.data[0].id // empty')
[ -n "$id" ] || die "identity $NAME not found; run scripts/ziti-tofu.sh apply first"

if ssh "$CTRL_HOST" "test -s $DEST"; then
  $reenroll || die "$DEST exists; rerun with --reenroll to replace it"
fi

if $reenroll; then
  say "Dropping the old certificate and enrolment of $NAME"
  zcli "edge delete authenticators where 'identity=\"$id\"'" >/dev/null || true
  zcli "edge delete enrollments where 'identity=\"$id\"'" >/dev/null || true
fi

say "One-time token for $NAME"
# The enrollments filter has no `method` field: pick the ott one here.
jwt=$(zcli "edge list enrollments 'identity=\"$id\"' -j" | jq -r '[.data[] | select(.method == "ott")][0].jwt // empty')
if [ -z "$jwt" ]; then
  zcli "edge create enrollment ott $NAME -o /tmp/$NAME.jwt" >/dev/null
else
  printf '%s' "$jwt" | ssh "$CTRL_HOST" "umask 077; docker exec -i ziti-controller sh -c 'cat > /tmp/$NAME.jwt'"
fi
unset jwt

say "Enrolling on mljr into $DEST"
ssh "$CTRL_HOST" "set -eu; umask 077
  docker exec ziti-controller sh -c 'cd /tmp && ziti edge enroll --jwt $NAME.jwt --out $NAME.json >/dev/null 2>&1; rm -f $NAME.jwt'
  install -d -m 0750 -o root -g caddy /etc/caddy/ziti
  docker exec ziti-controller sh -c 'cat /tmp/$NAME.json && rm -f /tmp/$NAME.json' > $DEST.new
  [ -s $DEST.new ] || { rm -f $DEST.new; echo 'enrolment produced no identity file' >&2; exit 1; }
  chown root:caddy $DEST.new; chmod 0640 $DEST.new; mv $DEST.new $DEST
  restorecon $DEST 2>/dev/null || true" \
  || die "enrolment failed"

say "Done: $DEST (root:caddy 0640)"
