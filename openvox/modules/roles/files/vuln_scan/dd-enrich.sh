#!/usr/bin/env bash
# Fills EPSS and CISA KEV on the active DefectDojo findings.
#
# DefectDojo's Trivy parser leaves epss_score / known_exploited empty (only
# Grype-style parsers set them, and the OSS edition has no enrichment job), so
# every finding looked equally urgent and the report's KEV rule could never
# fire. This looks the CVEs up once a day and PATCHes only the findings whose
# values changed, so after the first run it touches a few dozen at most.
#
#   EPSS: FIRST.org API, batches of 100 CVEs.
#   KEV:  CISA's known_exploited_vulnerabilities.json (also gives the date
#         added and the ransomware flag).
#
# A finding with several CVE ids takes the highest EPSS and any KEV hit. CVEs
# unknown to FIRST (very new, or non-CVE ids such as GHSA) stay empty and are
# not retried until a run finds them, which costs nothing.
#
# Usage: dd-enrich.sh [--dry-run]   (prints what it would change)
# Env:   see dd-lib.sh; KEV_URL / EPSS_URL override the feeds (tests)
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=dd-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/dd-lib.sh"

kev_url="${KEV_URL:-https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json}"
epss_url="${EPSS_URL:-https://api.first.org/data/v1/epss}"
dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

dojo_login
api() { curl -sS --fail-with-body --max-time 120 -H "Authorization: Token $DOJO_TOKEN" "$@"; }

# 1. active findings, only the fields compared below
: >"$workdir/findings.jsonl"
offset=0
while :; do
  page=$(api "$DOJO_URL/api/v2/findings/?active=true&limit=500&offset=$offset")
  jq -c '.results[] | {id, ids: [.vulnerability_ids[]?.vulnerability_id], epss_score, epss_percentile, known_exploited, kev_date, ransomware_used}' \
    <<<"$page" >>"$workdir/findings.jsonl"
  [ "$(jq '.next != null' <<<"$page")" = true ] || break
  offset=$((offset + 500))
done
total=$(wc -l <"$workdir/findings.jsonl")
echo "active findings: $total"

# 2. KEV catalogue
curl -sS --fail --max-time 120 "$kev_url" | jq '[.vulnerabilities[] | {key: .cveID, value: {date: .dateAdded, ransomware: (.knownRansomwareCampaignUse == "Known")}}] | from_entries' >"$workdir/kev.json"
echo "kev entries: $(jq 'length' "$workdir/kev.json")"

# 3. EPSS for every distinct CVE, 100 per request
jq -r '.ids[] | select(startswith("CVE-"))' "$workdir/findings.jsonl" | sort -u >"$workdir/cves.txt"
echo "distinct CVEs: $(wc -l <"$workdir/cves.txt")"
split -l 100 "$workdir/cves.txt" "$workdir/batch."
: >"$workdir/epss.jsonl"
for batch_file in "$workdir"/batch.*; do
  [ -e "$batch_file" ] || continue
  curl -sS --fail --max-time 60 --retry 2 --retry-delay 5 "$epss_url?cve=$(paste -sd, "$batch_file")&limit=100" \
    | jq -c '.data[]? | {key: .cve, value: {s: (.epss | tonumber), p: (.percentile | tonumber)}}' >>"$workdir/epss.jsonl"
done
jq -s 'from_entries' "$workdir/epss.jsonl" >"$workdir/epss.json"
echo "epss known: $(jq 'length' "$workdir/epss.json")"

# 4. desired value per finding; keep only the ones that differ
jq -c --slurpfile kev "$workdir/kev.json" --slurpfile epss "$workdir/epss.json" '
  . as $f
  | ($f.ids | map(select(startswith("CVE-")))) as $cves
  | ([$cves[] | $epss[0][.] | select(. != null)] | max_by(.s)) as $e
  | ([$cves[] | $kev[0][.] | select(. != null)] | first) as $k
  | {id: $f.id,
     epss_score: ($e.s // null), epss_percentile: ($e.p // null),
     known_exploited: ($k != null), kev_date: ($k.date // null),
     ransomware_used: ($k.ransomware // false)} as $want
  | select($want.epss_score != $f.epss_score or $want.epss_percentile != $f.epss_percentile
           or $want.known_exploited != $f.known_exploited or $want.kev_date != $f.kev_date
           or $want.ransomware_used != $f.ransomware_used)
  | $want' "$workdir/findings.jsonl" >"$workdir/patches.jsonl"
changes=$(wc -l <"$workdir/patches.jsonl")
echo "findings to update: $changes (known exploited: $(jq -s 'map(select(.known_exploited)) | length' "$workdir/patches.jsonl"))"

if [ "$dry_run" = true ]; then
  jq -c 'select(.known_exploited)' "$workdir/patches.jsonl" | head -10
  exit 0
fi

# 5. apply
failed=0
while IFS= read -r line; do
  id=$(jq -r .id <<<"$line")
  if ! jq 'del(.id)' <<<"$line" \
    | api -X PATCH -H "Content-Type: application/json" -d @- "$DOJO_URL/api/v2/findings/$id/" -o /dev/null; then
    echo "FAILED: finding $id" >&2
    failed=$((failed + 1))
  fi
done <"$workdir/patches.jsonl"
echo "updated: $((changes - failed)), failed: $failed"
[ "$failed" -eq 0 ]
