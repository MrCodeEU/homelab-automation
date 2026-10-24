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
# Authentication (DOJO_TOKEN, an importer account, or the admin): see dd-lib.sh.
#
# Usage: dd-import.sh --scan-type "Trivy Scan" --file report.json \
#          --product nuc --engagement trivy-nightly --test-title <title>
# Env:   DOJO_URL, DOJO_ENV_FILE, DOJO_TOKEN, DOJO_USER, DOJO_PASSWORD_FILE
#        (see dd-lib.sh)
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=dd-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/dd-lib.sh"

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
if [ ! -e "$file" ]; then
  echo "dd-import: report file missing: $file" >&2
  exit 2
fi

dojo_login

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
  -F minimum_severity=Info) || {
  echo "dd-import: import of $test_title into $product failed: $response" >&2
  exit 1
}

echo "$response" | jq -r '"imported \(.scan_type) into test \(.test) (\(.statistics.after.total.active // 0) active findings)"' 2>/dev/null \
  || echo "imported $test_title"
