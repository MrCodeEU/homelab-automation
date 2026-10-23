#!/usr/bin/env bash
# Read-only check for dojo-importer-apply.sh (noop-safe split, see AGENTS.md).
# Exit 0 when every importer in $IMPORTERS_FILE can log in to DefectDojo and
# sees its own product; exit 1 otherwise, which makes Puppet run the apply.
# Testing the real login also catches a rotated password.
#
# Env: DOJO_URL         base URL, default http://127.0.0.1:8101
#      IMPORTERS_FILE   lines of "<name>:<password>", default /etc/vuln-scan/importers
set -uo pipefail

DOJO_URL="${DOJO_URL:-http://127.0.0.1:8101}"
IMPORTERS_FILE="${IMPORTERS_FILE:-/etc/vuln-scan/importers}"

[ -r "$IMPORTERS_FILE" ] || exit 1

while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="${line%%:*}"
  password="${line#*:}"
  token=$(jq -n --arg u "import-$name" --arg p "$password" '{username: $u, password: $p}' \
    | curl -sS --max-time 30 -X POST "$DOJO_URL/api/v2/api-token-auth/" \
        -H 'Content-Type: application/json' --data @- 2>/dev/null \
    | jq -er .token 2>/dev/null) || exit 1
  curl -sS --max-time 30 -G "$DOJO_URL/api/v2/products/" \
      -H @<(printf 'Authorization: Token %s\n' "$token") \
      --data-urlencode "name=$name" 2>/dev/null \
    | jq -e --arg n "$name" '[.results[]? | select(.name == $n)] | length == 1' >/dev/null 2>&1 || exit 1
done < "$IMPORTERS_FILE"
