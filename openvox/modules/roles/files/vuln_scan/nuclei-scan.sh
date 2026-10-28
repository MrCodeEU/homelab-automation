#!/usr/bin/env bash
# Scans the public hostnames from the services catalog with Nuclei, from this
# host's connection, and imports the report into DefectDojo (see dd-import.sh).
# nuc reaches mljr's Caddy over the internet like any outside client, so this
# is the "what does the internet see" view; a scan over the tailnet would be
# a different vantage point.
#
# Nuclei runs from its official pinned container. Templates are refreshed
# first (into a named volume) so a CVE template published today is used
# tonight. Out-of-band (interactsh) checks are off, so nothing is sent to
# third-party servers, and DoS/fuzzing/intrusive templates are excluded. The
# source IP is allowlisted in CrowdSec (mljr-local-allowlist.yaml), so the
# scan is not banned; it also means this scan does not exercise CrowdSec's
# blocking.
#
# Usage: nuclei-scan.sh [--dry-run]    (dry run: scan and summarise, no import)
# Env:   NUCLEI_IMAGE   pinned Nuclei container image (required)
#        NUCLEI_TARGETS file with one URL per line (required)
#        DOJO_PRODUCT   DefectDojo product for the external view (required)
#        NUCLEI_SEVERITY default medium,high,critical
set -uo pipefail

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

: "${NUCLEI_IMAGE:?NUCLEI_IMAGE is required}"
: "${NUCLEI_TARGETS:?NUCLEI_TARGETS is required}"
: "${DOJO_PRODUCT:?DOJO_PRODUCT is required}"
severity="${NUCLEI_SEVERITY:-medium,high,critical}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ ! -s "$NUCLEI_TARGETS" ]; then
  echo "FAILED: no targets in $NUCLEI_TARGETS" >&2
  exit 1
fi
cp "$NUCLEI_TARGETS" "$workdir/targets.txt"

nuclei() {
  # --log-driver none: the scripts capture stdout themselves. With the default
  # json-file driver the whole JSON report also landed in Docker's log, Alloy
  # shipped it to Loki, and words like "thiserror" in CVE text became error
  # signatures on a random container name (dreamy_goldberg, funny_clarke).
  docker run --rm --log-driver none --security-opt label=disable \
    -v nuclei-data:/root \
    -v "$workdir":/work \
    "$NUCLEI_IMAGE" "$@"
}

echo "== updating templates"
if ! nuclei -update-templates; then
  echo "FAILED: nuclei template update (scanning with the templates already present)" >&2
  update_failed=true
fi

echo "== scanning $(wc -l < "$workdir/targets.txt") targets"
if ! nuclei -list /work/targets.txt -severity "$severity" \
    -exclude-tags dos,fuzz,intrusive -no-interactsh -disable-update-check \
    -rate-limit 300 -concurrency 50 -bulk-size 50 -timeout 10 -retries 1 \
    -jsonl -silent -output /work/report.jsonl; then
  echo "FAILED: nuclei scan" >&2
  exit 1
fi
touch "$workdir/report.jsonl"

findings=$(wc -l < "$workdir/report.jsonl")
echo "== $findings findings"
if [ "$dry_run" = true ]; then
  jq -r '"\(.info.severity)\t\(.["template-id"])\t\(.["matched-at"])"' "$workdir/report.jsonl"
  exit 0
fi

# An empty report is imported on purpose: reimport closes findings that no
# longer appear, which is how a fixed issue gets resolved.
if ! "$script_dir/dd-import.sh" --scan-type "Nuclei Scan" --file "$workdir/report.jsonl" \
    --product "$DOJO_PRODUCT" --engagement nuclei-nightly \
    --test-title "public hostnames from $(hostname -s)"; then
  echo "FAILED: import into DefectDojo" >&2
  exit 1
fi
[ "${update_failed:-false}" = true ] && exit 1
exit 0
