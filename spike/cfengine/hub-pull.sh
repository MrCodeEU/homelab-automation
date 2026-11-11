#!/bin/bash
# hub-pull: put the spike policy from git into the hub's masterfiles.
# Every commit since the last one applied must be signed by an allowed
# key, and the new head must be a fast forward of it. cf-serverd then
# serves the policy; the MPF only hands it out after cf-promises passed.
set -euo pipefail
repo=https://github.com/MrCodeEU/homelab-automation.git
branch=${SPIKE_PULL_BRANCH:-spike/pull}
state=/var/lib/spike-pull
mf=/var/cfengine/masterfiles
mkdir -p "$state"
[ -d "$state/repo/.git" ] || git clone -q --no-checkout --single-branch -b "$branch" "$repo" "$state/repo"
cd "$state/repo"
git fetch -q origin "$branch"
head=$(git rev-parse FETCH_HEAD)
last=$(cat "$state/last-applied" 2>/dev/null || true)
if [ -n "$last" ]; then
  [ "$last" = "$head" ] && exit 0
  git merge-base --is-ancestor "$last" "$head" || { echo "refusing $head: not a fast forward of $last" >&2; exit 1; }
  range="$last..$head"
else
  range="$head -1"
fi
# shellcheck disable=SC2086  # range is one or two words on purpose
for c in $(git rev-list $range); do
  git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/etc/spike-pull/allowed_signers verify-commit "$c" 2>/dev/null \
    || { echo "refusing $head: $c is not signed by an allowed key" >&2; exit 1; }
done
git -c advice.detachedHead=false checkout -q --detach "$head"
src=spike/cfengine
install -d -m 0755 "$mf/services/spike" "$mf/data"
install -m 0644 "$src/def.json" "$mf/def.json"
install -m 0644 "$src/services/spike/main.cf" "$mf/services/spike/main.cf"
install -m 0644 "$src/data/spike.json" "$mf/data/spike.json"
rsync -a --delete --chmod=D700,F600 "$src/hostsecrets/" /var/cfengine/spike-secrets/
echo "$head" > "$state/last-applied"
echo "applied $head"
