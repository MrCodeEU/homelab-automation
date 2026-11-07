#!/usr/bin/env bash
# Ziti services and policies as code (ziti/tofu/, docs/ZERO_TRUST_PLAN.md
# Phase 4). OpenTofu runs in a container on mljr against the controller's
# admin API on 127.0.0.1:8440: the netfoundry/ziti provider skips TLS
# verification on every management call (C3), so it must never talk to
# the controller over a network path.
#
# The *.tf files and the lock file are copied to $WORK on mljr; state stays
# there (encrypted with ZITI_TOFU_KEY from /opt/ziti-controller/.env, eyaml
# vault_ziti_tofu_key) and is part of the controller's cold backup. .tf
# files that are no longer in the repo are removed from $WORK, so a
# deleted resource is deleted on the controller too.
#
# Usage: scripts/ziti-tofu.sh plan            show what apply would change
#        scripts/ziti-tofu.sh apply [--yes]   plan, confirm, apply that plan
#        scripts/ziti-tofu.sh lock            refresh ziti/tofu/.terraform.lock.hcl
# shellcheck disable=SC2029  # remote commands are built locally on purpose
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net
TOFU_IMAGE=ghcr.io/opentofu/opentofu:1.13.9@sha256:f5aef7f2632b490e3c289a239d7974497d0583f3df6bfa35e8eb31a367ee5ec0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/ziti/tofu"
WORK=${ZITI_TOFU_WORK:-/opt/ziti-controller/tofu}

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Copy the config to $WORK, dropping .tf files the repo no longer has.
sync_config() {
  ssh "$CTRL_HOST" "install -d -m 700 $WORK && find $WORK -maxdepth 1 -name '*.tf' -delete"
  local files=("$SRC"/*.tf)
  [ -f "$SRC/.terraform.lock.hcl" ] && files+=("$SRC/.terraform.lock.hcl")
  scp -q "${files[@]}" "$CTRL_HOST:$WORK/"
}

# tofu <args>: one OpenTofu run in $WORK. Secrets go from .env into the
# container's environment, never onto a command line.
tofu() {
  local tty=-i
  [ -t 0 ] && [ -t 1 ] && tty=-it
  ssh -t "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
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
      0) echo "No changes."; ssh "$CTRL_HOST" "rm -f $WORK/tfplan"; exit 0 ;;
      2) ;;
      *) die "plan failed" ;;
    esac
    if [ "${2:-}" != --yes ]; then
      read -r -p "Apply this plan? [y/N] " answer
      [ "$answer" = y ] || { ssh "$CTRL_HOST" "rm -f $WORK/tfplan"; die "not applied"; }
    fi
    tofu apply -input=false tfplan
    ssh "$CTRL_HOST" "rm -f $WORK/tfplan"
    ;;
  lock)
    sync_config
    ssh "$CTRL_HOST" "rm -f $WORK/.terraform.lock.hcl"
    tofu init -input=false >/dev/null
    scp -q "$CTRL_HOST:$WORK/.terraform.lock.hcl" "$SRC/.terraform.lock.hcl"
    echo "updated ziti/tofu/.terraform.lock.hcl"
    ;;
  *) die "usage: $0 plan | apply [--yes] | lock" ;;
esac
