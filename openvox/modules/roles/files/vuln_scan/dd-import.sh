#!/usr/bin/env bash
# Imports one scanner report into DefectDojo. Shared by the Trivy and Nuclei
# scan timers, so scan-type specific logic lives in the callers, not here.
#
# Uses /api/v2/reimport-scan/ with auto_create_context, so the product,
# engagement and test are created on first use and every later import of the
# same (product, engagement, test title, scan type) updates that test:
# unchanged findings are deduplicated, findings missing from the new report
# are closed (close_old_findings), reappearing ones are reopened.
#
# Authentication: logs in as the DefectDojo admin with the password from
# DefectDojo's own .env (the file Puppet renders from eyaml), so no extra
# secret has to be provisioned. The API token is fetched per invocation and
# never put on a command line (visible in `ps`).
#
# Usage: dd-import.sh --scan-type "Trivy Scan" --file report.json \
#          --product nuc --engagement trivy-nightly --test-title <title>
# Env:   DOJO_URL       base URL, default http://127.0.0.1:8101
#        DOJO_ENV_FILE  default /opt/defectdojo/.env
#        DOJO_TOKEN     skip the login when already known
set -euo pipefail

DOJO_URL="${DOJO_URL:-http://127.0.0.1:8101}"
DOJO_ENV_FILE="${DOJO_ENV_FILE:-/opt/defectdojo/.env}"

scan_type="" file="" product="" engagement="" test_title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scan-type) scan_type="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --product) product="$2"; shift 2 ;;
    --engagement) engagement="$2"; shift 2 ;;
    --test-title) test_title="$2"; shift 2 ;;
    *) echo "dd-import: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for var in scan_type file product engagement test_title; do
  if [ -z "${!var}" ]; then
    echo "dd-import: --${var//_/-} is required" >&2
    exit 2
  fi
done
if [ ! -s "$file" ]; then
  echo "dd-import: report file missing or empty: $file" >&2
  exit 2
fi

if [ -z "${DOJO_TOKEN:-}" ]; then
  if [ ! -r "$DOJO_ENV_FILE" ]; then
    echo "dd-import: cannot read $DOJO_ENV_FILE" >&2
    exit 1
  fi
  password=$(grep -m1 '^DD_ADMIN_PASSWORD=' "$DOJO_ENV_FILE" | cut -d= -f2-)
  if [ -z "$password" ]; then
    echo "dd-import: DD_ADMIN_PASSWORD not set in $DOJO_ENV_FILE" >&2
    exit 1
  fi
  DOJO_TOKEN=$(jq -n --arg u admin --arg p "$password" '{username: $u, password: $p}' \
    | curl -sS --fail-with-body --max-time 30 -X POST "$DOJO_URL/api/v2/api-token-auth/" \
        -H 'Content-Type: application/json' --data @- \
    | jq -er .token)
fi

response=$(curl -sS --fail-with-body --max-time 600 -X POST "$DOJO_URL/api/v2/reimport-scan/" \
  -H @<(printf 'Authorization: Token %s\n' "$DOJO_TOKEN") \
  -F "scan_type=$scan_type" \
  -F "file=@$file" \
  -F product_type_name=Homelab \
  -F "product_name=$product" \
  -F "engagement_name=$engagement" \
  -F "test_title=$test_title" \
  -F auto_create_context=true \
  -F close_old_findings=true \
  -F active=true \
  -F verified=false \
  -F minimum_severity=Info)

echo "$response" | jq -r '"imported \(.scan_type) into test \(.test) (\(.statistics.after.total.active // 0) active findings)"' 2>/dev/null \
  || echo "imported $test_title"
