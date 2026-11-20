#!/usr/bin/env bash
# Ziti services and policies as code (ziti/tofu/, docs/ZERO_TRUST_PLAN.md
# Phase 4). OpenTofu runs in a container on mljr against the controller's
# admin API on 127.0.0.1:8440: the netfoundry/ziti provider skips TLS
# verification on every management call (C3), so it must never talk to
# the controller over a network path.
#
# The *.tf files and the lock file are copied to $WORK on mljr, and
# openvox/data/common.yaml plus the node files to $WORK/openvox-data/
# (ziti/tofu/catalog.tf generates services from them); state stays
# there (encrypted with ZITI_TOFU_KEY from /opt/ziti-controller/.env, eyaml
# vault_ziti_tofu_key) and is part of the controller's cold backup. .tf
# files that are no longer in the repo are removed from $WORK, so a
# deleted resource is deleted on the controller too.
#
# Usage: scripts/ziti-tofu.sh plan            show what apply would change
#        scripts/ziti-tofu.sh apply [--yes]   plan, confirm, apply that plan
#        scripts/ziti-tofu.sh lock            refresh ziti/tofu/.terraform.lock.hcl
#        scripts/ziti-tofu.sh auto            for mljr's deploy agent: apply
#                                             unless the plan destroys or
#                                             replaces something (exit 3)
#        scripts/ziti-tofu.sh check           drift check: plan, exit 2 when
#                                             the controller differs
#
# ZITI_TOFU_LOCAL=1: run on the controller host itself (the deploy agent
# runs this script from its exported tree on mljr), no ssh or scp.
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

CTRL_HOST=root@mljr.ziti
LOCAL=${ZITI_TOFU_LOCAL:-0}
# SSH over Ziti with the opkssh key (scripts/opk-ready.sh); not on mljr.
[ "$LOCAL" = 1 ] || "$(dirname "${BASH_SOURCE[0]}")/opk-ready.sh"
TOFU_IMAGE=ghcr.io/opentofu/opentofu:1.13.9@sha256:f5aef7f2632b490e3c289a239d7974497d0583f3df6bfa35e8eb31a367ee5ec0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/ziti/tofu"
WORK=${ZITI_TOFU_WORK:-/opt/ziti-controller/tofu}

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# on_ctrl <shell>: run on the controller host; cp_ctrl <src...> <dest>.
on_ctrl() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"; else ssh "$CTRL_HOST" "$1"; fi
}
cp_ctrl() {
  local dest=${*: -1}
  if [ "$LOCAL" = 1 ]; then cp "${@:1:$#-1}" "$dest"; else scp -q "${@:1:$#-1}" "$CTRL_HOST:$dest"; fi
}

# Copy the config and catalog data to $WORK, dropping .tf files the repo
# no longer has. Node files only, no secrets (those are in secrets/).
sync_config() {
  on_ctrl "install -d -m 700 $WORK && find $WORK -maxdepth 1 -name '*.tf' -delete \
    && rm -rf $WORK/openvox-data && install -d -m 700 $WORK/openvox-data/nodes"
  local files=("$SRC"/*.tf)
  [ -f "$SRC/.terraform.lock.hcl" ] && files+=("$SRC/.terraform.lock.hcl")
  cp_ctrl "${files[@]}" "$WORK/"
  cp_ctrl "$REPO/openvox/data/common.yaml" "$WORK/openvox-data/"
  cp_ctrl "$REPO"/openvox/data/nodes/*.int.mljr.eu.yaml "$WORK/openvox-data/nodes/"
}

# tofu <args>: one OpenTofu run in $WORK. Secrets go from .env into the
# container's environment, never onto a command line.
tofu() {
  local tty=-i ssh=(ssh -t "$CTRL_HOST")
  [ -t 0 ] && [ -t 1 ] && tty=-it
  [ "$LOCAL" = 1 ] && ssh=(bash -c)
  "${ssh[@]}" "set -a; . /opt/ziti-controller/.env; set +a
    [ -n \"\${ZITI_TOFU_KEY:-}\" ] || { echo 'ZITI_TOFU_KEY missing in /opt/ziti-controller/.env' >&2; exit 1; }
    export ZITI_API_PASSWORD=\"\$ZITI_ADMIN_PASSWORD\" TF_VAR_state_passphrase=\"\$ZITI_TOFU_KEY\"
    unset ZITI_ADMIN_PASSWORD ZITI_TOFU_KEY
    docker run --rm $tty --network host -v $WORK:/w:Z -w /w \
      -e TF_IN_AUTOMATION=1 -e TF_VAR_state_passphrase \
      -e ZITI_API_HOST=https://127.0.0.1:8440/edge/management/v1 \
      -e ZITI_API_USERNAME=admin -e ZITI_API_PASSWORD \
      $TOFU_IMAGE $*"
}

cmd=${1:-plan}
case $cmd in
  plan)
    sync_config
    tofu init -input=false -lockfile=readonly >/dev/null
    tofu plan -input=false
    ;;
  apply)
    sync_config
    tofu init -input=false -lockfile=readonly >/dev/null
    rc=0
    tofu plan -input=false -detailed-exitcode -out=tfplan || rc=$?
    case $rc in
      0) echo "No changes."; on_ctrl "rm -f $WORK/tfplan"; exit 0 ;;
      2) ;;
      *) die "plan failed" ;;
    esac
    if [ "${2:-}" != --yes ]; then
      read -r -p "Apply this plan? [y/N] " answer
      [ "$answer" = y ] || { on_ctrl "rm -f $WORK/tfplan"; die "not applied"; }
    fi
    tofu apply -input=false tfplan
    on_ctrl "rm -f $WORK/tfplan"
    ;;
  auto)
    # Unattended: a merge to main is the approval for additions and
    # in-place changes. Anything the plan deletes (destroy, or replace:
    # delete + create) waits for a person, because a recreated identity
    # loses its enrolment and a deleted policy cuts access.
    sync_config
    tofu init -input=false -lockfile=readonly >/dev/null
    rc=0
    tofu plan -input=false -no-color -detailed-exitcode -out=tfplan || rc=$?
    case $rc in
      0) echo "No changes."; on_ctrl "rm -f $WORK/tfplan"; exit 0 ;;
      2) ;;
      *) on_ctrl "rm -f $WORK/tfplan"; die "plan failed" ;;
    esac
    # No plan JSON, no apply: a failed read must not look like "no deletes".
    plan_json=$(tofu show -json tfplan) || { on_ctrl "rm -f $WORK/tfplan"; die "cannot read the plan"; }
    deletes=$(jq -er '[.resource_changes[]? | select(.change.actions | index("delete")) | "\(.address) (\(.change.actions | join("+")))"] | join("\n")' <<<"$plan_json") \
      || { on_ctrl "rm -f $WORK/tfplan"; die "cannot read the plan"; }
    if [ -n "$deletes" ]; then
      on_ctrl "rm -f $WORK/tfplan"
      printf 'HELD: the plan deletes or replaces resources, apply by hand (scripts/ziti-tofu.sh apply):\n%s\n' "$deletes"
      exit 3
    fi
    tofu apply -input=false -no-color tfplan
    on_ctrl "rm -f $WORK/tfplan"
    ;;
  check)
    sync_config
    tofu init -input=false -lockfile=readonly >/dev/null
    tofu plan -input=false -no-color -detailed-exitcode
    ;;
  lock)
    [ "$LOCAL" = 1 ] && die "lock runs from a checkout, not on the controller"
    sync_config
    on_ctrl "rm -f $WORK/.terraform.lock.hcl"
    tofu init -input=false >/dev/null
    scp -q "$CTRL_HOST:$WORK/.terraform.lock.hcl" "$SRC/.terraform.lock.hcl"
    echo "updated ziti/tofu/.terraform.lock.hcl"
    ;;
  *) die "usage: $0 plan | apply [--yes] | lock | auto | check" ;;
esac
