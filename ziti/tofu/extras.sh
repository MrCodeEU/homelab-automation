#!/usr/bin/env bash
# What the netfoundry/ziti provider cannot manage, applied after tofu by
# scripts/ziti-tofu.sh on the controller host (from $WORK, next to the
# .tf files):
#   permissions.txt  identity permissions (admin_readonly, ...)
#   updb.txt         username/password authenticators
# An identity that does not exist yet is skipped: tofu creates it in the
# same run, the next run sets it.
#
# Usage: extras.sh [--check]   --check only reports, exit 2 on drift.
# Talks to the management API on the admin listener as the default admin;
# passwords come from /opt/ziti-controller/.env and never reach a command
# line (request bodies are built by jq from the environment).
set -euo pipefail

mode="set"
[ "${1:-}" = --check ] && mode=check
dir=$(cd "$(dirname "$0")" && pwd)
set -a
# shellcheck disable=SC1091
. /opt/ziti-controller/.env
set +a

api=https://localhost:8440/edge/management/v1
c() {
  curl -sS --fail-with-body --cacert /opt/ziti-controller/data/pki/root/certs/root.cert \
    --connect-to localhost:8440:127.0.0.1:8440 -H 'content-type: application/json' "$@"
}
# login <user> <password variable>: prints the session token, empty if refused.
login() {
  U=$1 P=${!2:-} jq -n '{username: env.U, password: env.P}' \
    | c -d @- "$api/authenticate?method=password" 2>/dev/null | jq -r '.data.token // empty' || true
}
logout() { c -X DELETE -H "zt-session: $1" "$api/current-api-session" >/dev/null || true; }

tok=$(login admin ZITI_ADMIN_PASSWORD)
[ -n "$tok" ] || { echo "extras: admin login failed" >&2; exit 1; }
trap 'logout "$tok"' EXIT
get() { c -H "zt-session: $tok" "$api/$1"; }
send() { c -X "$1" -H "zt-session: $tok" -d @- "$api/$2" >/dev/null; }
identity() { get "identities?filter=$(jq -rn --arg n "$1" '"name=\"\($n)\"" | @uri')" | jq -c '.data[0] // empty'; }

drift=0
note() {
  if [ "$mode" = check ]; then echo "drift: $*"; drift=1; else echo "extras: $*"; fi
}

while read -r name want; do
  case $name in '' | '#'*) continue ;; esac
  id=$(identity "$name")
  [ -n "$id" ] || { echo "extras: $name does not exist yet, skipped"; continue; }
  cur=$(jq -r '(.permissions // []) | sort | join(",")' <<<"$id")
  want=$(tr ',' '\n' <<<"$want" | sort | paste -sd, -)
  [ "$cur" = "$want" ] && continue
  note "$name permissions '$cur' -> '$want'"
  [ "$mode" = check ] && continue
  W=$want jq -n '{permissions: (env.W | split(","))}' | send PATCH "identities/$(jq -r .id <<<"$id")"
done <"$dir/permissions.txt"

while read -r name user var; do
  case $name in '' | '#'*) continue ;; esac
  id=$(identity "$name")
  [ -n "$id" ] || { echo "extras: $name does not exist yet, skipped"; continue; }
  [ -n "${!var:-}" ] || { echo "extras: $var is empty in /opt/ziti-controller/.env" >&2; exit 1; }
  iid=$(jq -r .id <<<"$id")
  auth=$(get "authenticators?filter=$(jq -rn --arg i "$iid" '"identity=\"\($i)\"" | @uri')" \
    | jq -c '[.data[] | select(.method == "updb")][0] // empty')
  if [ -z "$auth" ]; then
    note "$name has no password login, creating $user"
    [ "$mode" = check ] && continue
    I=$iid U=$user P=${!var} jq -n '{method: "updb", identityId: env.I, username: env.U, password: env.P}' \
      | send POST authenticators
    continue
  fi
  if [ "$(jq -r .username <<<"$auth")" != "$user" ]; then
    note "$name username '$(jq -r .username <<<"$auth")' -> '$user'"
  elif t=$(login "$user" "$var") && [ -n "$t" ]; then
    logout "$t"
    continue
  else
    note "$name password differs from $var"
  fi
  [ "$mode" = check ] && continue
  U=$user P=${!var} jq -n '{username: env.U, password: env.P}' | send PATCH "authenticators/$(jq -r .id <<<"$auth")"
done <"$dir/updb.txt"

[ "$drift" = 0 ] || exit 2
