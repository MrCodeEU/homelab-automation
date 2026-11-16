#!/usr/bin/env bash
# What a deploy of this checkout would change, per host, without any host:
# the catalog diff (scripts/catalog-diff.sh) from the commit last requested
# on deploy/<host> to this checkout. Markdown on stdout.
#
#   catalog-check.sh [host ...]     (default: nuc mljr ugreen)
#
# deploy.yml's check mode (a run on a non-main branch) runs this instead of
# a live noop. The base is the newest request on deploy/<host>, read from
# the public repository; if that deploy failed, the host may still be on
# an older commit. Hosts with the same base are compiled together.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slug="${GITHUB_REPOSITORY:-MrCodeEU/homelab-automation}"
hosts=("$@")
[ "${#hosts[@]}" -gt 0 ] || hosts=(nuc mljr ugreen)

declare -A group
for h in "${hosts[@]}"; do
  [[ "$h" =~ ^[a-z0-9-]+$ ]] || { echo "invalid host: $h" >&2; exit 2; }
  commit="$(curl -fsSL --retry 3 --max-time 30 \
    "https://raw.githubusercontent.com/${slug}/deploy/${h}/.deploy/request.json" | jq -r '.commit // empty')"
  # Checked before it reaches git: the branch is written by deploy.yml only,
  # but nothing here should trust that.
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "deploy/$h: no valid request commit" >&2; exit 1; }
  group[$commit]+="$h "
done

for commit in "${!group[@]}"; do
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$commit"
  list="${group[$commit]% }"
  echo "diff ${commit:0:9}..HEAD for: $list" >&2
  "$repo/scripts/catalog-diff.sh" --hosts "$list" \
    --title "Catalog diff from the deployed ${commit:0:9} ($list)" --ref "$commit"
  echo
done
