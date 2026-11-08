#!/usr/bin/env bash
# Enrol a machine-to-machine proxy identity (ziti/tofu/m2m.tf) on the host
# that runs it, into <base_path>/<service>/data/<name>.json for
# services/<service> (base_path: roles::services::base_path of that host).
# The identity itself is created by OpenTofu (scripts/ziti-tofu.sh apply);
# this only turns its one-time token into a certificate and key.
#
# The token is fetched on mljr (controller) and piped over SSH; enrolment
# runs on the target host in a throwaway container of the router image, so
# the private key never leaves that host. The file is 2171:2171 0600 (the
# image's user).
#
# Usage: scripts/ziti-enroll-proxy.sh <identity> <host> <service> [--reenroll]
#   e.g. scripts/ziti-enroll-proxy.sh m2m-mljr mljr ziti-proxy
#        scripts/ziti-enroll-proxy.sh m2m-ugreen ugreen ziti-proxy-ugreen
#   --reenroll  replace an existing enrolment (lost or broken file): drops
#               the identity's certificate authenticator, issues a new token
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage="usage: $0 <identity> <host> <service> [--reenroll]"
[ $# -ge 3 ] || die "$usage"
NAME=$1
HOST=$2
SERVICE=$3
reenroll=false
case "${4:-}" in
  "") ;;
  --reenroll) reenroll=true ;;
  *) die "$usage" ;;
esac
[[ $NAME =~ ^[a-z0-9-]+$ ]] || die "bad identity name: $NAME"
[[ $HOST =~ ^[a-z0-9-]+$ ]] || die "bad host: $HOST"
[[ $SERVICE =~ ^ziti-proxy(-[a-z0-9]+)?$ ]] || die "bad service: $SERVICE"

repo=$(cd "$(dirname "$0")/.." && pwd)
compose=$repo/services/$SERVICE/docker-compose.yml
node=$repo/openvox/data/nodes/$HOST.int.mljr.eu.yaml
[ -f "$compose" ] || die "no $compose"
[ -f "$node" ] || die "no $node"
grep -q -- "/identity/$NAME.json" "$compose" || die "$compose does not use identity $NAME"
base=$(sed -n "s/^roles::services::base_path: *['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$node")

CTRL_HOST=root@mljr.tail33930.ts.net
TARGET=root@$HOST.tail33930.ts.net
DIR=${base:-/opt}/$SERVICE/data
DEST=$DIR/$NAME.json
IMAGE=$(sed -n 's/^ *image: *//p' "$compose" | head -1)
[ -n "$IMAGE" ] || die "no image in $compose"

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

id=$(zcli "edge list identities 'name=\"$NAME\"' -j" | jq -r '.data[0].id // empty')
[ -n "$id" ] || die "identity $NAME not found; run scripts/ziti-tofu.sh apply first"

if ssh "$TARGET" "test -s $DEST"; then
  $reenroll || die "$DEST exists on $HOST; rerun with --reenroll to replace it"
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
  jwt=$(zcli "edge list enrollments 'identity=\"$id\"' -j" | jq -r '[.data[] | select(.method == "ott")][0].jwt // empty')
  ssh "$CTRL_HOST" "docker exec ziti-controller rm -f /tmp/$NAME.jwt"
fi
[ -n "$jwt" ] || die "no one-time token for $NAME"

say "Enrolling on $HOST into $DEST"
printf '%s' "$jwt" | ssh "$TARGET" "set -eu; umask 077
  install -d -m 0700 -o 2171 -g 2171 $DIR
  cat > $DIR/$NAME.jwt; chown 2171:2171 $DIR/$NAME.jwt
  docker run --rm --network host --entrypoint ziti -v $DIR:/w -w /w $IMAGE \
    edge enroll --jwt $NAME.jwt --out $NAME.json.new >/dev/null 2>&1 || true
  rm -f $DIR/$NAME.jwt
  [ -s $DIR/$NAME.json.new ] || { rm -f $DIR/$NAME.json.new; echo 'enrolment produced no identity file' >&2; exit 1; }
  chown 2171:2171 $DIR/$NAME.json.new; chmod 0600 $DIR/$NAME.json.new
  mv $DIR/$NAME.json.new $DEST
  restorecon -R $DIR 2>/dev/null || true" \
  || die "enrolment failed"
unset jwt

say "Done: $DEST on $HOST (2171:2171 0600)"
