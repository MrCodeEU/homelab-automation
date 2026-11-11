#!/usr/bin/env bash
# Create a deploy request for one host (docs/DEPLOY_AGENT.md): a commit on
# the orphan branch deploy/<host> with .deploy/request.json, made with
# GraphQL createCommitOnBranch so GitHub signs it (the REST git-data API
# does not). The host's deploy-agent picks it up within a minute.
#
#   deploy-request.sh <host> [commit] [trigger]
#
# <commit> defaults to the current origin/main, <trigger> to manual.
# Needs gh with write access to the repository.
set -euo pipefail

host="${1:?usage: deploy-request.sh <host> [commit] [trigger]}"
[[ "$host" =~ ^[a-z0-9-]{1,63}$ ]] || { echo "invalid host: $host" >&2; exit 2; }
repo="${DEPLOY_REPO:-MrCodeEU/homelab-automation}"
api="repos/${repo}"
branch="deploy/${host}"
commit="${2:-$(gh api "${api}/git/ref/heads/main" -q .object.sha)}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be a full sha: $commit" >&2; exit 2; }
trigger="${3:-manual}"

# The branch starts with an unsigned README commit; the agent only ever
# trusts the signed request at its head.
if ! head=$(gh api "${api}/git/ref/heads/${branch}" -q .object.sha 2>/dev/null); then
  blob=$(gh api "${api}/git/blobs" -f content="Deploy requests for ${host}. See docs/DEPLOY_AGENT.md." -f encoding=utf-8 -q .sha)
  tree=$(gh api "${api}/git/trees" -f 'tree[][path]=README' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=${blob}" -q .sha)
  head=$(gh api "${api}/git/commits" -f message="${branch}: start" -f tree="$tree" -q .sha)
  gh api "${api}/git/refs" -f ref="refs/heads/${branch}" -f sha="$head" -q .ref >/dev/null
fi

id="$(date -u +%Y%m%dT%H%M%SZ)"
request=$(printf '{"id":"%s","host":"%s","commit":"%s","trigger":"%s"}\n' "$id" "$host" "$commit" "$trigger")
# expectedHeadOid makes this a compare-and-swap: a concurrent request fails
# instead of being overwritten.
# shellcheck disable=SC2016 # $input is a GraphQL variable, not shell
gh api graphql \
  -f query='mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  -F "input[branch][repositoryNameWithOwner]=${repo}" -F "input[branch][branchName]=${branch}" \
  -F "input[expectedHeadOid]=${head}" -F "input[message][headline]=deploy ${host} ${commit:0:9} (${trigger})" \
  -F "input[fileChanges][additions][][path]=.deploy/request.json" \
  -F "input[fileChanges][additions][][contents]=$(printf %s "$request" | base64 -w0)" \
  -q .data.createCommitOnBranch.commit.oid >/dev/null
echo "requested ${id}: ${host} at ${commit:0:9}"
