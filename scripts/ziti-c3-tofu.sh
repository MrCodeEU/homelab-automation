#!/usr/bin/env bash
# C3 (docs/ZERO_TRUST_PLAN.md): can OpenTofu with the netfoundry/ziti
# provider create, update and delete services and policies on the
# self-hosted controller, with an empty plan after each apply?
#
# Runs OpenTofu in a container on mljr against the admin API on
# 127.0.0.1:8440: the provider skips TLS verification on every API call
# (internal/provider/common.go, v2.2.1), so it must not talk to the
# controller over any network path.
#
#   1. apply ziti/tofu-c3/main.tf (variant 1), plan must be empty
#   2. apply variant 2 (changed port, roles, attributes; one policy
#      removed), plan must be empty, the controller must show the change
#   3. adoption check: import blocks for the live ssh service objects and
#      shared policies, `plan -generate-config-out`, never applied
#   4. destroy, no c3 object may be left
#
# Usage: scripts/ziti-c3-tofu.sh
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net
TOFU_IMAGE=ghcr.io/opentofu/opentofu:1.13.9@sha256:f5aef7f2632b490e3c289a239d7974497d0583f3df6bfa35e8eb31a367ee5ec0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=/root/c3-tofu

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# tofu <args>: one OpenTofu run in $WORK/<dir> on mljr. The admin password
# goes from .env into the container's environment, never onto a command line.
tofu_in() { # dir args...
  local dir=$1; shift
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    export ZITI_API_PASSWORD=\"\$ZITI_ADMIN_PASSWORD\"; unset ZITI_ADMIN_PASSWORD
    docker run --rm --network host -v $WORK/$dir:/w -v $WORK/plugins:/plugins -w /w \
      -e TF_PLUGIN_CACHE_DIR=/plugins -e TF_IN_AUTOMATION=1 \
      -e ZITI_API_HOST=https://127.0.0.1:8440/edge/management/v1 \
      -e ZITI_API_USERNAME=admin -e ZITI_API_PASSWORD \
      $TOFU_IMAGE $*"
}
zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}
# plan_empty dir args...: exit 0 = no changes, 2 = changes, 1 = error.
plan_empty() {
  local dir=$1 rc=0; shift
  tofu_in "$dir" plan -no-color -input=false -detailed-exitcode "$@" >/dev/null || rc=$?
  case $rc in
    0) echo "    plan after apply: empty" ;;
    2) tofu_in "$dir" plan -no-color -input=false "$@" | grep -E '^\s+[~+-] |# ' | head -30
       die "plan after apply is not empty" ;;
    *) die "plan failed" ;;
  esac
}
c3_objects() {
  for t in configs services service-policies edge-router-policies service-edge-router-policies; do
    zcli "edge list $t 'name contains \"c3\"' -j" | jq -r --arg t "$t" '.data[] | "\($t) \(.name)"'
  done
}

cleanup() {
  say "Cleaning up"
  [ -n "${applied:-}" ] && tofu_in main destroy -auto-approve -no-color -input=false -var variant=2 >/dev/null 2>&1 || true
  ssh "$CTRL_HOST" "rm -rf $WORK" || true
}
trap cleanup EXIT

say "Copying the fixture to mljr:$WORK (0700)"
ssh "$CTRL_HOST" "umask 077; rm -rf $WORK; mkdir -p $WORK/main $WORK/adopt $WORK/plugins"
scp -q "$REPO/ziti/tofu-c3/main.tf" "$CTRL_HOST:$WORK/main/main.tf"
[ -z "$(c3_objects)" ] || die "c3 objects exist already: $(c3_objects | tr '\n' ' ')"

say "1. init + apply variant 1"
tofu_in main init -no-color -input=false | grep -E 'Installed|Installing|has been successfully' || die "init failed"
applied=1
tofu_in main apply -auto-approve -no-color -input=false -var variant=1 | grep -E 'Apply complete|Error'
plan_empty main -var variant=1
c3_objects | sed 's/^/    /'

say "2. apply variant 2 (port 7002, roles changed, SERP removed)"
tofu_in main apply -auto-approve -no-color -input=false -var variant=2 | grep -E 'Apply complete|Error'
plan_empty main -var variant=2
echo "    controller sees:"
zcli "edge list configs 'name=\"c3-host\"' -j" | jq -r '.data[] | "      c3-host port \(.data.port)"'
zcli "edge list services 'name=\"c3\"' -j" | jq -r '.data[] | "      c3 roleAttributes \(.roleAttributes|join(","))"'
zcli "edge list service-policies 'name=\"c3-bind\"' -j" | jq -r '.data[] | "      c3-bind identityRoles \(.identityRoles|join(","))"'
zcli "edge list edge-router-policies 'name=\"c3-erp\"' -j" | jq -r '.data[] | "      c3-erp edgeRouterRoles \(.edgeRouterRoles|join(","))"'
if [ -n "$(zcli "edge list service-edge-router-policies 'name=\"c3-serp\"' -j" | jq -r '.data[]')" ]; then
  die "c3-serp still exists"
fi
echo "      c3-serp: deleted"

say "3. adoption check: import the live ssh objects (plan only)"
imports=""
add_import() { # resource-type name list-type
  local id
  id=$(zcli "edge list $3 'name=\"$2\"' -j" | jq -r '.data[0].id')
  [ -n "$id" ] && [ "$id" != null ] || die "$3 $2 not found"
  imports+="import {
  to = $1.$(echo "$2" | tr -- '-' '_')
  id = \"$id\"
}
"
}
add_import ziti_intercept_v1_config ssh-intercept configs
add_import ziti_host_v1_config ssh-host configs
add_import ziti_service ssh services
add_import ziti_service_policy ssh-bind service-policies
add_import ziti_edge_router_policy all-identities-all-routers edge-router-policies
add_import ziti_service_edge_router_policy all-services-all-routers service-edge-router-policies
{ sed -n '/^terraform {/,/^}/p' "$REPO/ziti/tofu-c3/main.tf"; echo 'provider "ziti" {}'; printf '%s' "$imports"; } \
  | ssh "$CTRL_HOST" "cat > $WORK/adopt/main.tf"
tofu_in adopt init -no-color -input=false >/dev/null || die "adopt init failed"
tofu_in adopt plan -no-color -input=false -generate-config-out=generated.tf 2>&1 \
  | grep -E '^Plan:|will be imported|Error|Warning' | sed 's/^/    /'
echo "    second plan against the generated config:"
tofu_in adopt plan -no-color -input=false 2>&1 | grep -E '^Plan:|^\s+[~+-] |Error' | sed 's/^/    /'
echo "    generated config:"
ssh "$CTRL_HOST" "cat $WORK/adopt/generated.tf" | grep -vE '^\s*#|^\s*$' | sed 's/^/      /'

say "4. destroy"
tofu_in main destroy -auto-approve -no-color -input=false -var variant=2 | grep -E 'Destroy complete|Error'
applied=
left=$(c3_objects)
[ -z "$left" ] || die "left behind: $left"
echo "    no c3 objects left"
