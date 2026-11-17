#!/usr/bin/env bash
# Show the one-time enrolment token of a phone identity (ziti/tofu/phone.tf)
# as a QR code, for Ziti Mobile Edge's "add identity" scanner. The token is
# fetched from the controller on mljr and only drawn in this terminal: run
# it in your own terminal, not through an agent or CI (the token enrols
# whoever scans it first, until it is used or expires).
#
# After the scan, in the app: open the identity, enable MFA, add the TOTP to
# Bitwarden and keep the recovery codes there. Until then the identity
# reaches nothing (posture check mfa-mobile).
#
# Usage: scripts/ziti-enroll-phone.sh <identity> [--reenroll]
#   e.g. scripts/ziti-enroll-phone.sh phone-mrcode
#   --reenroll  new phone or broken enrolment: drops the identity's
#               certificate and issues a new token
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage="usage: $0 <identity> [--reenroll]"
[ $# -ge 1 ] || die "$usage"
NAME=$1
reenroll=false
case "${2:-}" in
  "") ;;
  --reenroll) reenroll=true ;;
  *) die "$usage" ;;
esac
[[ $NAME =~ ^[a-z0-9-]+$ ]] || die "bad identity name: $NAME"
[ -t 1 ] || die "stdout is not a terminal: run this yourself, the QR code is a credential"

CTRL_HOST=${ZITI_CTRL_SSH:-root@mljr.tail33930.ts.net}
# Drawn by qrencode in a throwaway container: nothing to install, and the
# token only passes through its stdin.
QR_IMAGE=docker.io/library/alpine:3.22

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

id=$(zcli "edge list identities 'name=\"$NAME\"' -j" | jq -r '.data[0].id // empty')
[ -n "$id" ] || die "identity $NAME not found; run scripts/ziti-tofu.sh apply first"
enrolled=$(zcli "edge list authenticators 'identity=\"$id\"' -j" | jq -r '.data | length')
if [ "$enrolled" != "0" ] && ! $reenroll; then
  die "$NAME is already enrolled; rerun with --reenroll for a new phone"
fi
if $reenroll; then
  say "Dropping the old certificate and enrolment of $NAME"
  zcli "edge delete authenticators where 'identity=\"$id\"'" >/dev/null || true
  zcli "edge delete enrollments where 'identity=\"$id\"'" >/dev/null || true
fi

# The enrollments filter has no `method` field: pick the ott one here.
token() { zcli "edge list enrollments 'identity=\"$id\"' -j" | jq -r '[.data[] | select(.method == "ott")][0] | "\(.jwt // "")\t\(.expiresAt // "")"'; }
IFS=$'\t' read -r jwt expires < <(token)
if [ -z "$jwt" ]; then
  zcli "edge create enrollment ott $NAME -o /tmp/$NAME.jwt" >/dev/null
  ssh "$CTRL_HOST" "docker exec ziti-controller rm -f /tmp/$NAME.jwt"
  IFS=$'\t' read -r jwt expires < <(token)
fi
[ -n "$jwt" ] || die "no one-time token for $NAME"

say "Scan with Ziti Mobile Edge (+ > scan QR code); token valid until $expires"
printf '%s' "$jwt" | docker run --rm -i "$QR_IMAGE" sh -c \
  'apk add -q --no-progress libqrencode-tools >/dev/null && qrencode -t ansiutf8'
unset jwt
read -r -p "Press Enter once the phone shows the identity as enrolled (this clears the screen). "
clear
enrolled=$(zcli "edge list authenticators 'identity=\"$id\"' -j" | jq -r '.data | length')
if [ "$enrolled" = "0" ]; then
  die "$NAME is not enrolled yet; rerun this script to show the token again"
fi
say "Enrolled. Now in the app: identity $NAME -> enable MFA, TOTP into Bitwarden, recovery codes too."
