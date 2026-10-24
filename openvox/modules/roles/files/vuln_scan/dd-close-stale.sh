#!/usr/bin/env bash
# Closes the findings of tests that are no longer scanned.
#
# One DefectDojo test per scan target, titled after the image reference. A
# version-pinned image that moves to a new tag gets a new test, and the old
# one is never imported again - so close_old_findings never runs on it and
# its findings stay active for good, inflating the totals and the alerts.
#
# Given the titles still scanned (one per line in --keep-file), every other
# test in the product's engagement that still has active findings gets an
# empty reimport, which closes them. A test whose target comes back is
# reopened by its next normal import.
#
# Usage: dd-close-stale.sh --product nuc --engagement trivy-nightly \
#          --scan-type "Trivy Scan" --empty-report empty.json --keep-file titles.txt
# Env:   see dd-lib.sh; DD_IMPORT overrides the dd-import.sh path (tests)
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=dd-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/dd-lib.sh"
dd_import="${DD_IMPORT:-$(dirname "${BASH_SOURCE[0]}")/dd-import.sh}"

product="" engagement="" scan_type="" empty_report="" keep_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --product) product="$2"; shift 2 ;;
    --engagement) engagement="$2"; shift 2 ;;
    --scan-type) scan_type="$2"; shift 2 ;;
    --empty-report) empty_report="$2"; shift 2 ;;
    --keep-file) keep_file="$2"; shift 2 ;;
    *) echo "dd-close-stale: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for var in product engagement scan_type empty_report keep_file; do
  if [ -z "${!var}" ]; then
    echo "dd-close-stale: --${var//_/-} is required" >&2
    exit 2
  fi
done

dojo_login
api="$DOJO_URL/api/v2"

# $1 path under /api/v2 (with query string)
dojo_get() {
  curl -sS --fail-with-body --max-time 60 "$api/$1" \
    -H @<(printf 'Authorization: Token %s\n' "$DOJO_TOKEN")
}
urlenc() { jq -rn --arg v "$1" '$v | @uri'; }

# The name filters match substrings, hence the exact select. No product or
# engagement yet means nothing was ever imported: nothing to close.
product_id=$(dojo_get "products/?limit=1000&name=$(urlenc "$product")" \
  | jq -r --arg n "$product" '[.results[] | select(.name == $n)][0].id // empty')
[ -n "$product_id" ] || exit 0
engagement_id=$(dojo_get "engagements/?limit=1000&product=$product_id&name=$(urlenc "$engagement")" \
  | jq -r --arg n "$engagement" '[.results[] | select(.name == $n)][0].id // empty')
[ -n "$engagement_id" ] || exit 0

closed=0 failed=0
while IFS=$'\t' read -r test_id title; do
  [ -n "$test_id" ] || continue
  if grep -qxF -- "$title" "$keep_file"; then
    continue
  fi
  active=$(dojo_get "findings/?test=$test_id&active=true&limit=1" | jq -r '.count')
  [ "$active" -gt 0 ] || continue
  if "$dd_import" --scan-type "$scan_type" --file "$empty_report" \
      --product "$product" --engagement "$engagement" --test-title "$title" >/dev/null; then
    echo "closed $active finding(s) of the no longer scanned target: $title"
    closed=$((closed + 1))
  else
    echo "dd-close-stale: failed to close $title" >&2
    failed=$((failed + 1))
  fi
done < <(dojo_get "tests/?limit=1000&engagement=$engagement_id" \
  | jq -r '.results[] | [.id, .title] | @tsv')

echo "stale tests closed: $closed"
[ "$failed" -eq 0 ]
