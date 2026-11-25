#!/usr/bin/env bash
# Fails when a change adds an openziti/ziti-* image tag that is not a stable
# GitHub release of openziti/ziti. Docker Hub also carries tags for GitHub
# pre-releases, and Renovate's docker datasource cannot tell them apart:
# 2.0.9 (a pre-release) came in that way with #715. Required checks hold
# Renovate's automerge, so such a PR stays open with this check red.
#
# Only tags the change adds are checked (diff against BASE_REF), so a
# pre-release that is already running on purpose does not fail every PR.
# A tag that is already pinned somewhere in BASE_REF is no new version
# either (a new router copying the fleet's pin), so it passes as well.
# Usage: BASE_REF=origin/main scripts/check-openziti-stable.sh
# Needs gh (GH_TOKEN in CI).
set -euo pipefail
base="${BASE_REF:-origin/main}"
tags=$(git diff --unified=0 "${base}...HEAD" -- services scripts openvox ziti \
  | grep -E '^\+' | grep -v '^+++' \
  | grep -oE 'openziti/ziti-(controller|router|cli|tunnel):[0-9]+\.[0-9]+\.[0-9]+[^@"[:space:]]*' \
  | cut -d: -f2 | sort -u || true)
if [ -z "$tags" ]; then
  echo "no new openziti/ziti-* image tags"
  exit 0
fi
fail=0
for t in $tags; do
  if git grep -q -E "openziti/ziti-(controller|router|cli|tunnel):${t//./\\.}([^0-9.]|$)" "$base" -- services scripts openvox ziti; then
    echo "ok   ${t}: already pinned in ${base}"
    continue
  fi
  if ! pre=$(gh api "repos/openziti/ziti/releases/tags/v${t}" -q .prerelease 2>/dev/null); then
    echo "FAIL ${t}: no GitHub release v${t} in openziti/ziti"
    fail=1
  elif [ "$pre" = true ]; then
    echo "FAIL ${t}: v${t} is a pre-release on GitHub; wait for the stable release"
    fail=1
  else
    echo "ok   ${t}: stable release"
  fi
done
exit "$fail"
