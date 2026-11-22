#!/usr/bin/env bash
# Enrol the wd-mycloud identity (ziti/tofu/wd-mycloud.tf) on the WD My
# Cloud itself, into /mnt/HD/HD_a2/ziti/identity/wd-mycloud.json, with the
# ziti-edge-tunnel that roles::wd_mycloud_ziti_proxy installed there. The
# identity is created by OpenTofu (scripts/ziti-tofu.sh apply); this only
# turns its one-time token into a certificate and key, then starts the
# tunneler through its watchdog.
#
# The token is fetched on mljr (controller) and piped over SSH through nuc,
# the device's management proxy, so the private key never leaves the
# device. Device SSH: nuc's management path (Tailscale SSH until the
# switch to wd-mycloud-ssh over Ziti).
#
# Usage: scripts/ziti-enroll-wd-mycloud.sh [--reenroll]
#   --reenroll  replace an existing enrolment (lost or broken file): drops
#               the identity's certificate authenticator, issues a new token
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

# SSH over Ziti with the opkssh key (scripts/opk-ready.sh).
"$(dirname "${BASH_SOURCE[0]}")/opk-ready.sh"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

reenroll=false
case "${1:-}" in
  "") ;;
  --reenroll) reenroll=true ;;
  *) die "usage: $0 [--reenroll]" ;;
esac

NAME=wd-mycloud
CTRL_HOST=root@mljr.ziti
PROXY=root@nuc.ziti
DEVICE=root@wd-mycloud.tail33930.ts.net
BASE=/mnt/HD/HD_a2/ziti
DEST=$BASE/identity/$NAME.json

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}
device() { ssh "$PROXY" "ssh -o BatchMode=yes $DEVICE $(printf '%q' "$1")"; }

id=$(zcli "edge list identities 'name=\"$NAME\"' -j" | jq -r '.data[0].id // empty')
[ -n "$id" ] || die "identity $NAME not found; run scripts/ziti-tofu.sh apply first"

device "test -x $BASE/current/ziti-edge-tunnel" \
  || die "no ziti-edge-tunnel on the device yet; deploy nuc first (roles::wd_mycloud_ziti_proxy)"

if device "test -s $DEST"; then
  $reenroll || die "$DEST exists on the device; rerun with --reenroll to replace it"
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

say "Enrolling on the device into $DEST"
remote="set -eu; umask 077
  mkdir -p $BASE/identity; chmod 0700 $BASE/identity
  cat > $BASE/identity/$NAME.jwt
  out=\$($BASE/current/ziti-edge-tunnel enroll --jwt $BASE/identity/$NAME.jwt --identity $DEST.new 2>&1) || true
  rm -f $BASE/identity/$NAME.jwt
  [ -s $DEST.new ] || { rm -f $DEST.new; printf '%s\n' \"\$out\" | tail -5 >&2; echo 'enrolment produced no identity file' >&2; exit 1; }
  chmod 0600 $DEST.new
  pkill -f '[z]iti-edge-tunnel run-host' || true
  mv $DEST.new $DEST
  sh $BASE/watchdog.sh"
printf '%s' "$jwt" | ssh "$PROXY" "ssh -o BatchMode=yes $DEVICE $(printf '%q' "$remote")" \
  || die "enrolment failed"
unset jwt

say "Done: $DEST on wd-mycloud; tunneler started (log $BASE/ziti-edge-tunnel.log)"
