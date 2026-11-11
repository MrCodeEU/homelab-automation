#!/usr/bin/env bash
# Build and verify the statically compiled Go binaries that are committed next
# to a service's Dockerfile. A committed binary can silently drift from its
# source (nobody rebuilt it), so every opted-in binary carries a sidecar
# <binary>.src-sha256: a hash of the source of the command and every
# module-local package it imports, plus go.mod/go.sum. CI recomputes it and
# fails when the source changed without a rebuild.
#
#   service-binary.sh build      <service> <cmd>  build + write the sidecar
#   service-binary.sh build-host <dir> <cmd>      same, for a host binary
#   service-binary.sh check                       verify every sidecar (CI)
#   service-binary.sh hash       <cmd>            print the source hash
#
# <service> is a directory under services/, <cmd> a directory under
# tools/cmd/; the binary is named after <cmd>. A host binary (not in a
# container, e.g. deploy-agent) goes to openvox/modules/roles/files/<dir>/,
# where its role installs it from. Opt a binary in by running `build` or
# `build-host` once and committing both files.
set -euo pipefail
# The source hash sorts file paths; without a fixed collation a de_AT or
# en_US locale orders `_` differently than CI's C locale and every
# binary with an underscore in a source file name looks stale.
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

src_hash() {
  local cmd="$1"
  (
    cd "$root/tools"
    {
      go list -deps -f '{{if and (not .Standard) .Module}}{{if .Module.Main}}{{.Dir}}{{end}}{{end}}' "./cmd/$cmd" 2>/dev/null \
        | while read -r dir; do
            [ -n "$dir" ] && find "$dir" -maxdepth 1 -type f -name '*.go' ! -name '*_test.go'
          done
      echo "$root/tools/go.mod"
      echo "$root/tools/go.sum"
    } | sort -u | while read -r f; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#"$root"/}"
    done | sha256sum | cut -d' ' -f1
  )
}

case "${1:-}" in
  hash)
    [ -n "${2:-}" ] || { echo "usage: $0 hash <cmd>" >&2; exit 2; }
    src_hash "$2"
    ;;
  build|build-host)
    dir="${2:-}"; cmd="${3:-}"
    if [ "$1" = build ]; then
      [ -d "$root/services/$dir" ] && [ -d "$root/tools/cmd/$cmd" ] || { echo "usage: $0 build <service> <cmd>" >&2; exit 2; }
      out="$root/services/$dir/$cmd"
    else
      [[ "$dir" =~ ^[a-z0-9_]+$ ]] && [ "$dir" != services ] && [ -d "$root/tools/cmd/$cmd" ] || { echo "usage: $0 build-host <dir> <cmd>" >&2; exit 2; }
      mkdir -p "$root/openvox/modules/roles/files/$dir"
      out="$root/openvox/modules/roles/files/$dir/$cmd"
    fi
    (cd "$root/tools" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o "$out" "./cmd/$cmd")
    src_hash "$cmd" > "$out.src-sha256"
    echo "built $out (source hash $(cat "$out.src-sha256" | cut -c1-12))"
    ;;
  check)
    status=0
    shopt -s nullglob
    # files/services/ holds synced copies of services/, checked there.
    for sidecar in "$root"/services/*/*.src-sha256 "$root"/openvox/modules/roles/files/*/*.src-sha256; do
      case "$sidecar" in "$root"/openvox/modules/roles/files/services/*) continue ;; esac
      bin="${sidecar%.src-sha256}"
      cmd="$(basename "$bin")"
      want="$(tr -d '[:space:]' < "$sidecar")"
      have="$(src_hash "$cmd")"
      if [ ! -x "$bin" ] && [ ! -f "$bin" ]; then
        echo "FAIL  $bin is missing"; status=1
      elif [ "$want" != "$have" ]; then
        echo "FAIL  ${bin#"$root"/} is stale: source changed since it was built. Run: scripts/service-binary.sh build $(basename "$(dirname "$bin")") $cmd"
        status=1
      else
        echo "OK    ${bin#"$root"/}"
      fi
    done
    exit $status
    ;;
  *)
    sed -n '2,16p' "$0"; exit 2 ;;
esac
