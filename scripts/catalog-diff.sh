#!/usr/bin/env bash
# Catalog diff of two openvox/ trees, per host, as Markdown on stdout:
#
#   catalog-diff.sh <base-openvox-dir> <head-openvox-dir>
#   catalog-diff.sh --ref <git-ref>        (base: that ref, head: this checkout)
#
# Compiles both with scripts/catalog-compile.sh (no hosts, no secrets) and
# compares them with tools/cmd/catalog-diff. Exit 1 when the head does not
# compile; a base that does not compile is only reported. The PR check
# "Catalog diff" runs this; `make catalog-diff [BASE=origin/main]` locally.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ "${1:-}" = "--ref" ]; then
  ref="${2:?--ref needs a git ref}"
  mkdir -p "$work/base"
  git -C "$repo" archive "$ref" openvox | tar -x -C "$work/base"
  base="$work/base/openvox"
  head="$repo/openvox"
else
  base="${1:?usage: catalog-diff.sh <base-openvox-dir> <head-openvox-dir> | --ref <git-ref>}"
  head="${2:?head openvox dir missing}"
fi

(cd "$repo/tools" && go build -o "$work/catalog-diff" ./cmd/catalog-diff)
echo "compiling base" >&2
"$repo/scripts/catalog-compile.sh" "$base" "$work/base-catalogs" >&2 || echo "base did not compile completely" >&2
echo "compiling head" >&2
"$repo/scripts/catalog-compile.sh" "$head" "$work/head-catalogs" >&2
"$work/catalog-diff" "$work/base-catalogs" "$work/head-catalogs" "$base" "$head"
