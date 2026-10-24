#!/usr/bin/env bash
# Shared by dd-import.sh and dd-close-stale.sh. Source it, do not run it.
#
# dojo_login sets DOJO_TOKEN unless it is already set. Authentication, in order:
#   DOJO_TOKEN                      used as is
#   DOJO_USER + DOJO_PASSWORD_FILE  a least-privilege importer account (see
#                                   dojo-importer-apply.sh), for hosts that
#                                   push to a remote DefectDojo
#   otherwise                       the DefectDojo admin with the password
#                                   from DefectDojo's own .env, which only
#                                   exists on the DefectDojo host itself
# The API token is fetched per invocation and never put on a command line
# (visible in `ps`).
#
# Env: DOJO_URL, DOJO_ENV_FILE, DOJO_USER, DOJO_PASSWORD_FILE

DOJO_URL="${DOJO_URL:-http://127.0.0.1:8101}"
DOJO_ENV_FILE="${DOJO_ENV_FILE:-/opt/defectdojo/.env}"

dojo_login() {
  [ -z "${DOJO_TOKEN:-}" ] || return 0
  local user="${DOJO_USER:-admin}" password
  if [ -n "${DOJO_USER:-}" ]; then
    if [ ! -r "${DOJO_PASSWORD_FILE:-}" ]; then
      echo "dojo: cannot read DOJO_PASSWORD_FILE (${DOJO_PASSWORD_FILE:-unset})" >&2
      return 1
    fi
    password=$(cat "$DOJO_PASSWORD_FILE")
  else
    if [ ! -r "$DOJO_ENV_FILE" ]; then
      echo "dojo: cannot read $DOJO_ENV_FILE" >&2
      return 1
    fi
    password=$(grep -m1 '^DD_ADMIN_PASSWORD=' "$DOJO_ENV_FILE" | cut -d= -f2-)
  fi
  if [ -z "$password" ]; then
    echo "dojo: no password for $user" >&2
    return 1
  fi
  DOJO_TOKEN=$(jq -n --arg u "$user" --arg p "$password" '{username: $u, password: $p}' \
    | curl -sS --fail-with-body --max-time 30 -X POST "$DOJO_URL/api/v2/api-token-auth/" \
        -H 'Content-Type: application/json' --data @- \
    | jq -er .token) || return 1
}
