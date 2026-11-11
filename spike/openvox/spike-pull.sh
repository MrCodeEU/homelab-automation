#!/bin/bash
# spike-pull: option C prototype. Fetch the branch, refuse anything whose
# head is not signed by an allowed key, then puppet apply that commit.
# Records the last success for monitoring.
set -euo pipefail
repo=https://github.com/MrCodeEU/homelab-automation.git
branch=${SPIKE_PULL_BRANCH:-spike/pull}
state=/var/lib/spike-pull
mkdir -p "$state"
[ -d "$state/repo/.git" ] || git clone -q --no-checkout --filter=blob:none --single-branch -b "$branch" "$repo" "$state/repo"
cd "$state/repo"
git fetch -q origin "$branch"
head=$(git rev-parse FETCH_HEAD)
if ! git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/etc/spike-pull/allowed_signers verify-commit "$head" 2>/dev/null; then
  echo "refusing $head: not signed by an allowed key" >&2
  exit 1
fi
git -c advice.detachedHead=false checkout -q --detach "$head"
cd spike/openvox
rc=0
/opt/puppetlabs/bin/puppet apply --detailed-exitcodes --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp || rc=$?
# 0: no change, 2: changes. 4/6: failures.
if [ "$rc" = 0 ] || [ "$rc" = 2 ]; then
  printf '%s %s\n' "$(date +%s)" "$head" > "$state/last-success"
else
  exit "$rc"
fi
