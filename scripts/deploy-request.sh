#!/usr/bin/env bash
# Create a deploy request for one host (docs/DEPLOY_AGENT.md): a commit on
# the orphan branch deploy/<host> with .deploy/request.json, made with
# GraphQL createCommitOnBranch so GitHub signs it (the REST git-data API
# does not). The host's deploy-agent picks it up within a minute.
#
#   deploy-request.sh <host> [commit] [trigger]
#
# <commit> defaults to the current main, <trigger> to manual. The deploy.yml
# inputs come from the environment, checked against the same allowlist the
# agent applies:
#
#   DEPLOY_REQUEST_SERVICE           repository_dispatch service name
#   DEPLOY_REQUEST_STAGING_SERVICES  comma list
#   DEPLOY_REQUEST_DOCKER_PRUNE      true|false
#   DEPLOY_REQUEST_REBOOT_IF_NEEDED  true|false
#   DEPLOY_REQUEST_ID_SUFFIX         appended to the id, e.g. the run id
#
# Needs gh with write access to the repository (GH_TOKEN in CI) and jq.
set -euo pipefail

host="${1:?usage: deploy-request.sh <host> [commit] [trigger]}"
[[ "$host" =~ ^[a-z0-9-]{1,63}$ ]] || { echo "invalid host: $host" >&2; exit 2; }
repo="${DEPLOY_REPO:-MrCodeEU/homelab-automation}"
api="repos/${repo}"
branch="deploy/${host}"
commit="${2:-$(gh api "${api}/git/ref/heads/main" -q .object.sha)}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be a full sha: $commit" >&2; exit 2; }
trigger="${3:-manual}"
case "$trigger" in workflow_dispatch|schedule|repository_dispatch|manual) ;; *) echo "invalid trigger: $trigger" >&2; exit 2 ;; esac

service="${DEPLOY_REQUEST_SERVICE:-}"
staging="${DEPLOY_REQUEST_STAGING_SERVICES:-}"
prune="${DEPLOY_REQUEST_DOCKER_PRUNE:-false}"
reboot="${DEPLOY_REQUEST_REBOOT_IF_NEEDED:-false}"
suffix="${DEPLOY_REQUEST_ID_SUFFIX:-}"
name_re='^[A-Za-z0-9._-]{1,64}$'
[ -z "$service" ] || [[ "$service" =~ $name_re ]] || { echo "invalid service: $service" >&2; exit 2; }
if [ -n "$staging" ]; then
  [ "${#staging}" -le 256 ] || { echo "staging services longer than 256" >&2; exit 2; }
  IFS=, read -ra names <<< "$staging"
  for n in "${names[@]}"; do [[ "$n" =~ $name_re ]] || { echo "invalid staging service: $n" >&2; exit 2; }; done
fi
for b in "$prune" "$reboot"; do case "$b" in true|false) ;; *) echo "not a boolean: $b" >&2; exit 2 ;; esac; done
[ -z "$suffix" ] || [[ "$suffix" =~ ^[0-9A-Za-z]{1,40}$ ]] || { echo "invalid id suffix: $suffix" >&2; exit 2; }

# The branch starts with an unsigned README commit; the agent only ever
# trusts the signed request at its head.
if ! gh api "${api}/git/ref/heads/${branch}" >/dev/null 2>&1; then
  blob=$(gh api "${api}/git/blobs" -f content="Deploy requests for ${host}. See docs/DEPLOY_AGENT.md." -f encoding=utf-8 -q .sha)
  tree=$(gh api "${api}/git/trees" -f 'tree[][path]=README' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=${blob}" -q .sha)
  root=$(gh api "${api}/git/commits" -f message="${branch}: start" -f tree="$tree" -q .sha)
  gh api "${api}/git/refs" -f ref="refs/heads/${branch}" -f sha="$root" -q .ref >/dev/null
fi

# expectedHeadOid makes each request a compare-and-swap: a concurrent
# request fails instead of being overwritten, and this one is retried on
# top of it with a fresh id.
for attempt in 1 2 3; do
  head=$(gh api "${api}/git/ref/heads/${branch}" -q .object.sha)
  id="$(date -u +%Y%m%dT%H%M%SZ)${suffix:+-$suffix}"
  request=$(jq -cn --arg id "$id" --arg host "$host" --arg commit "$commit" --arg trigger "$trigger" \
    --arg service "$service" --arg staging "$staging" --argjson prune "$prune" --argjson reboot "$reboot" \
    '{id: $id, host: $host, commit: $commit, trigger: $trigger, service: $service,
      staging_services: $staging, docker_prune: $prune, reboot_if_needed: $reboot}')
  # shellcheck disable=SC2016 # $input is a GraphQL variable, not shell
  if gh api graphql \
    -f query='mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
    -F "input[branch][repositoryNameWithOwner]=${repo}" -F "input[branch][branchName]=${branch}" \
    -F "input[expectedHeadOid]=${head}" -F "input[message][headline]=deploy ${host} ${commit:0:9} (${trigger})" \
    -F "input[fileChanges][additions][][path]=.deploy/request.json" \
    -F "input[fileChanges][additions][][contents]=$(printf '%s\n' "$request" | base64 -w0)" \
    -q .data.createCommitOnBranch.commit.oid >/dev/null; then
    echo "requested ${id}: ${host} at ${commit:0:9} (${trigger})"
    exit 0
  fi
  echo "request for ${host} failed (attempt ${attempt}), retrying" >&2
  sleep $((attempt * 2))
done
echo "could not create a request for ${host}" >&2
exit 1
