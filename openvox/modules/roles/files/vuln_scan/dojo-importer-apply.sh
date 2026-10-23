#!/usr/bin/env bash
# Provisions one least-privilege DefectDojo user per remote host that pushes
# its scans here (see roles::vuln_scan $importers). Idempotent.
#
# Per "<name>:<password>" line in $IMPORTERS_FILE:
#   - product <name> in product type "Homelab" (created if missing)
#   - user import-<name>: active, NOT staff, NOT superuser, password set
#   - that user listed in the product's authorized_users
#
# DefectDojo's open-source edition has no roles; authorization is superuser,
# staff, or membership in a product's authorized_users. That membership lets
# the user import into exactly that product and nothing else: it cannot
# create products, read or touch other products, delete, or manage users.
#
# Authenticates as admin with DD_ADMIN_PASSWORD from DOJO_ENV_FILE. The
# tokens and passwords never appear on a command line.
#
# The API refuses password changes and enforces a password policy, and a user
# that has imported cannot be deleted, so the real password is always set
# inside the uwsgi container.
#
# Env: DOJO_URL, IMPORTERS_FILE (see dojo-importer-check.sh), DOJO_ENV_FILE
#      default /opt/defectdojo/.env
#      DOJO_EXEC  command that runs a process in the uwsgi container with
#                 no stdin, default "docker exec -e DOJO_PW defectdojo-uwsgi"
set -euo pipefail

DOJO_URL="${DOJO_URL:-http://127.0.0.1:8101}"
IMPORTERS_FILE="${IMPORTERS_FILE:-/etc/vuln-scan/importers}"
DOJO_ENV_FILE="${DOJO_ENV_FILE:-/opt/defectdojo/.env}"
DOJO_EXEC="${DOJO_EXEC:-docker exec -e DOJO_PW defectdojo-uwsgi}"
api="$DOJO_URL/api/v2"

admin_password=$(grep -m1 '^DD_ADMIN_PASSWORD=' "$DOJO_ENV_FILE" | cut -d= -f2-)
if [ -z "$admin_password" ]; then
  echo "dojo-importer: DD_ADMIN_PASSWORD not set in $DOJO_ENV_FILE" >&2
  exit 1
fi
token=$(jq -n --arg u admin --arg p "$admin_password" '{username: $u, password: $p}' \
  | curl -sS --fail-with-body --max-time 30 -X POST "$api/api-token-auth/" \
      -H 'Content-Type: application/json' --data @- \
  | jq -er .token)

# $1 method, $2 path (under /api/v2), $3 JSON body (optional). On failure the
# response body goes to stderr: DefectDojo explains what it rejected.
dojo() {
  local method="$1" path="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out=$(printf '%s' "$body" | curl -sS --fail-with-body --max-time 60 -X "$method" "$api/$path" \
      -H @<(printf 'Authorization: Token %s\n' "$token") \
      -H 'Content-Type: application/json' --data @-) || {
      echo "dojo-importer: $method $path failed: $out" >&2
      return 1
    }
  else
    out=$(curl -sS --fail-with-body --max-time 60 -X "$method" "$api/$path" \
      -H @<(printf 'Authorization: Token %s\n' "$token")) || {
      echo "dojo-importer: $method $path failed: $out" >&2
      return 1
    }
  fi
  printf '%s\n' "$out"
}

# $1 collection, $2 field, $3 value -> id of the exact match, empty if none.
# (The name filters are substring matches, hence the exact select.)
find_id() {
  dojo GET "$1/?limit=1000&$2=$(jq -rn --arg v "$3" '$v | @uri')" \
    | jq -r --arg f "$2" --arg v "$3" '[.results[] | select(.[$f] == $v)][0].id // empty'
}

# $1 username, $2 password. Passed through the environment so it never shows
# up in a process list.
set_password() {
  # shellcheck disable=SC2086 # DOJO_EXEC is a command prefix on purpose
  DOJO_PW="$2" $DOJO_EXEC python manage.py shell -c "
import os
from dojo.models import Dojo_User
u = Dojo_User.objects.get(username='$1')
u.set_password(os.environ['DOJO_PW'])
u.save()
" </dev/null >/dev/null
}

type_id=$(find_id product_types name Homelab)
if [ -z "$type_id" ]; then
  type_id=$(dojo POST product_types/ '{"name": "Homelab"}' | jq -er .id)
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="${line%%:*}"
  password="${line#*:}"
  username="import-$name"

  product_id=$(find_id products name "$name")
  if [ -z "$product_id" ]; then
    product_id=$(dojo POST products/ "$(jq -n --arg n "$name" --argjson t "$type_id" \
      '{name: $n, description: "Scans pushed by \($n)", prod_type: $t}')" | jq -er .id)
    echo "created product $name"
  fi

  user_id=$(find_id users username "$username")
  if [ -z "$user_id" ]; then
    # The API enforces DefectDojo's password policy (upper case, special
    # character), the shell route below does not. Create with a throwaway
    # compliant password, then set the real one.
    throwaway="Aa-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    user_id=$(dojo POST users/ "$(jq -n --arg u "$username" --arg p "$throwaway" \
      '{username: $u, email: "\($u)@homelab.invalid", password: $p,
        is_active: true, is_staff: false, is_superuser: false}')" | jq -er .id)
    echo "created user $username"
  else
    dojo PATCH "users/$user_id/" '{"is_active": true, "is_staff": false, "is_superuser": false}' >/dev/null
    echo "reset user $username"
  fi
  set_password "$username" "$password"

  members=$(dojo GET "products/$product_id/" \
    | jq -c --argjson u "$user_id" '(.authorized_users // []) + [$u] | unique')
  dojo PATCH "products/$product_id/" "$(jq -n --argjson m "$members" '{authorized_users: $m}')" >/dev/null
  echo "importer $username -> product $name ready"
done < "$IMPORTERS_FILE"
