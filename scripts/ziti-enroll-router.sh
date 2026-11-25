#!/usr/bin/env bash
# Enrol (or re-enrol) an OpenZiti edge router (docs/ZERO_TRUST_PLAN.md
# Phase 3). Run from the laptop; needs SSH to mljr and the router's host.
#
#   1. on mljr, log the controller CLI in with the admin password from
#      /opt/ziti-controller/.env (never printed)
#   2. create the edge router (tunneler enabled, role attribute) or, with
#      --reenroll, issue it a new token
#   3. pipe the one-time token (valid 3 h) from mljr through this shell
#      straight into <host>:/opt/<service>/data/enroll.jwt, owned by the
#      container user; it never lands on the laptop's disk
#   4. restart the router container, wait until the controller reports it
#      online, then delete the token
#
# Usage: scripts/ziti-enroll-router.sh <mljr|nuc|ugreen|nas|drill> [--reenroll]
# Deploy the router service first (the container restart-loops until the
# token is there; that is expected).
# Remote commands are built locally on purpose (names and paths are local
# constants), hence SC2029.
# shellcheck disable=SC2029
set -euo pipefail

# SSH over Ziti with the opkssh key (scripts/opk-ready.sh).
"$(dirname "${BASH_SOURCE[0]}")/opk-ready.sh"

CTRL_HOST=root@mljr.ziti
ZUID=2171 # ziggy, the image user

die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

name="${1:-}"
reenroll=false
[ "${2:-}" = --reenroll ] && reenroll=true
case "$name" in
  mljr) host=root@mljr.ziti; svc=ziti-router;     attr=public; base=/opt ;;
  nuc)  host=root@nuc.ziti;  svc=ziti-router-nuc; attr=lan;    base=/opt ;;
  ugreen) host=root@ugreen.ziti; svc=ziti-router-ugreen; attr=lan; base=/volume1/homelab ;;
  # DR drill VM (docs/DISASTER_RECOVERY.md): own attribute, not #lan
  drill) host=root@drill.ziti; svc=ziti-router-drill; attr=drill; base=/opt ;;
  # nas: nas-ssh is hosted by nas's own router (opkssh, roles::nas_opkssh),
  # so a first enrolment, or one while that router is down, needs the LAN:
  # NAS_SSH=root@192.168.50.80.
  nas) host=${NAS_SSH:-root@nas-ssh.ziti}; svc=ziti-router-nas; attr=lan; base=/mnt/user/appdata/homelab ;;
  *) die "usage: $0 <mljr|nuc|ugreen|nas|drill> [--reenroll]" ;;
esac
# base: roles::services::base_path of that host (docs/ZITI_ENROLL.md).
data="$base/$svc/data"
# On the controller a router is named after its host's certname, so the
# wildcard ssh service can address it (ziti/tofu/services.tf). The
# local name ($name) stays the router's file and container naming.
ctrl_name="$name.int.mljr.eu"

# Run a shell command on the router's host, through $via when it is set
# (stdin passes through both hops).
via="${via:-}"
rsh() {
  if [ -n "$via" ]; then
    ssh -o BatchMode=yes "$via" "ssh -o BatchMode=yes $host $(printf %q "$1")"
  else
    ssh -o BatchMode=yes "$host" "$1"
  fi
}

# Run a ziti CLI command inside the controller container, logged in. The
# password is read from .env on mljr and passed on mljr only.
zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

say "Router $name ($svc on ${host#root@})"
rsh "docker inspect $svc >/dev/null 2>&1" \
  || die "container $svc not found on ${host#root@}; deploy it first"

if zcli "edge list edge-routers 'name=\"$ctrl_name\"' -j" | grep -q "\"name\": *\"$ctrl_name\""; then
  $reenroll || die "router $ctrl_name already exists; rerun with --reenroll to issue a new token"
  say "Issuing a new enrolment token"
  zcli "edge re-enroll edge-router $ctrl_name -o /tmp/$name.jwt" >/dev/null
  rsh "f=$data/$name.cert; [ -f \$f ] && mv \$f \$f.\$(date +%Y%m%dT%H%M%S); true"
else
  say "Creating edge router $ctrl_name (attribute #$attr)"
  zcli "edge create edge-router $ctrl_name --tunneler-enabled -a $attr -o /tmp/$name.jwt" >/dev/null
fi

say "Handing the token to $svc"
ssh "$CTRL_HOST" "docker exec ziti-controller sh -c 'cat /tmp/$name.jwt && rm -f /tmp/$name.jwt'" \
  | rsh "set -eu; umask 077
      install -d -m 700 -o $ZUID -g $ZUID $data
      cat > $data/enroll.jwt
      [ -s $data/enroll.jwt ]
      chown $ZUID:$ZUID $data/enroll.jwt
      docker restart $svc >/dev/null" \
  || die "token handover failed"

say "Waiting for $name to come online"
online=false
for _ in $(seq 1 30); do
  if zcli "edge list edge-routers 'name=\"$ctrl_name\"' -j" | grep -q '"isOnline": *true'; then
    online=true; break
  fi
  sleep 3
done
rsh "rm -f $data/enroll.jwt"
$online || die "router $name did not come online; check: ssh ${host} docker logs $svc"
say "Router $name is enrolled and online."
