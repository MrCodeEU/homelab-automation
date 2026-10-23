#!/usr/bin/env bash
# Scans every running container image plus the host OS packages with Trivy
# and imports each report into DefectDojo (see dd-import.sh).
#
# Trivy runs from its official container, so nothing is installed on the host
# apart from the pinned image. The container needs the Docker socket (to read
# local images, including ones built on this host) and, for the host scan, a
# read-only view of / - hence label=disable under SELinux.
#
# One DefectDojo test per target: image scans are titled with the image
# reference, the host scan "host packages". Reports include HIGH and
# CRITICAL findings, unfixed ones too; deciding what is actionable is the
# alerting side's job.
#
# A failing target never stops the others. Exit status is non-zero when any
# target failed, so the systemd unit shows up as failed.
#
# Remote mode: with DOCKER_HOST=ssh://root@<host> every docker command runs on
# that host's daemon (Trivy included), while this script and the import stay
# local. For hosts that can't run timers or scripts of their own (Unraid).
# Set TRIVY_SCAN_HOST=false there: the OS packages of such a host are not
# something Trivy can read.
#
# Usage: trivy-scan.sh [--dry-run]    (dry run: scan and summarise, no import)
# Env:   TRIVY_IMAGE    pinned Trivy container image (required)
#        DOJO_PRODUCT   DefectDojo product, normally the host name (required)
#        TRIVY_SEVERITY default HIGH,CRITICAL
#        TRIVY_SCAN_HOST default true; false skips the host package scan
#        DOCKER_HOST    scan the containers of a remote daemon (see above)
set -uo pipefail

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"
: "${DOJO_PRODUCT:?DOJO_PRODUCT is required}"
severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
scan_host_packages="${TRIVY_SCAN_HOST:-true}"
engagement="trivy-nightly"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

trivy() {
  docker run --rm --security-opt label=disable \
    -v trivy-cache:/root/.cache \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$@" </dev/null
}

failed=0

# $1 test title, $2 report file
import_report() {
  if [ "$dry_run" = true ]; then
    jq -r --arg t "$1" '[.Results[]?.Vulnerabilities[]?] as $v
      | "\($t): \($v | length) findings (\($v | map(select(.Severity == "CRITICAL")) | length) critical)"' "$2"
    return 0
  fi
  "$script_dir/dd-import.sh" --scan-type "Trivy Scan" --file "$2" \
    --product "$DOJO_PRODUCT" --engagement "$engagement" --test-title "$1"
}

# $1 test title, $2 image to scan (an image ID, so it is exactly what runs)
scan_image() {
  local title="$1" target="$2" report="$workdir/image.json"
  echo "== image: $title"
  if ! trivy "$TRIVY_IMAGE" image --quiet --format json --scanners vuln \
      --severity "$severity" --timeout 10m "$target" > "$report"; then
    echo "FAILED: trivy image scan of $title" >&2
    failed=$((failed + 1))
    return
  fi
  if ! import_report "$title" "$report"; then
    echo "FAILED: import of $title" >&2
    failed=$((failed + 1))
  fi
}

scan_host() {
  local report="$workdir/host.json"
  echo "== host packages"
  if ! trivy -v /:/hostroot:ro "$TRIVY_IMAGE" rootfs --quiet --format json \
      --scanners vuln --pkg-types os --severity "$severity" --timeout 10m \
      --skip-dirs /hostroot/var/lib/docker --skip-dirs /hostroot/proc \
      --skip-dirs /hostroot/sys --skip-dirs /hostroot/dev --skip-dirs /hostroot/run \
      --skip-dirs /hostroot/mnt --skip-dirs /hostroot/srv /hostroot > "$report"; then
    echo "FAILED: trivy rootfs scan" >&2
    failed=$((failed + 1))
    return
  fi
  if ! import_report "host packages" "$report"; then
    echo "FAILED: import of host packages" >&2
    failed=$((failed + 1))
  fi
}

# Scan the image each container actually runs, by image ID: a tag may have
# moved on since the container was created, and that stale image is exactly
# what should be reported. The test title is the image reference, or the
# container name when docker only knows the image by ID (tag moved).
declare -A seen=()
# Listed up front, not through a process substitution: a failing docker (a
# remote daemon that is unreachable) must fail the run, not look like a host
# without containers.
if ! containers=$(docker ps --format '{{.Names}}\t{{.Image}}'); then
  echo "FAILED: cannot list containers" >&2
  exit 1
fi
while IFS=$'\t' read -r name ref; do
  [ -n "$name" ] || continue
  image_id=$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null </dev/null) || continue
  title="$ref"
  if [[ "$ref" =~ ^[0-9a-f]{12}$ ]]; then
    title="container $name"
  fi
  if [ -n "${seen[$title]:-}" ]; then
    continue
  fi
  seen[$title]=1
  # A container can outlive its image object (rebuilt local images whose old
  # image was removed): scan the current tag instead of failing, and skip
  # when there is no tag to fall back to.
  target="$image_id"
  if ! docker image inspect "$image_id" >/dev/null 2>&1 </dev/null; then
    if [[ "$ref" =~ ^[0-9a-f]{12}$ ]]; then
      echo "skipping $title: its image no longer exists" >&2
      continue
    fi
    echo "note: image of $title is gone, scanning current $ref instead" >&2
    target="$ref"
  fi
  scan_image "$title" "$target"
done < <(sort <<< "$containers")
if [ "$scan_host_packages" = true ]; then
  scan_host
fi

if [ "$failed" -gt 0 ]; then
  echo "$failed target(s) failed" >&2
  exit 1
fi
echo "all targets scanned"
