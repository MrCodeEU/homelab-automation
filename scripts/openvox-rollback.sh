#!/usr/bin/env bash
# shellcheck disable=SC2029
# Points a host's `production` environment symlink at a previous release
# (see openvox-sync.sh's release/symlink-swap logic) and re-applies, so a bad
# deploy can be undone without re-syncing anything. Does NOT restore service
# data/backups - this only rolls back manifests/hiera/data (roles code and
# eyaml-encrypted values), i.e. undoes a bad catalog, not a bad service state
# change the old catalog already caused before you noticed.
#
# Usage: openvox-rollback.sh <ssh-target> [steps-back]
#   steps-back defaults to 1 - the release immediately before the current one.
set -uo pipefail

host="${1:?usage: openvox-rollback.sh <ssh-target> [steps-back]}"
steps_back="${2:-1}"

if [[ ! "$steps_back" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid steps-back: $steps_back (must be a positive integer)" >&2
  exit 2
fi

env_dir="/etc/puppetlabs/code/environments/production"
env_base="$(dirname "$env_dir")"
releases_dir="${env_base}/releases"
# Forge modules are shared across releases (see openvox-sync.sh) - only
# env_dir/modules (this repo's own `roles` code) actually changes when the
# symlink swaps to an older release.
shared_modules_dir="${env_base}/vendor-modules"
module_path="${env_dir}/modules:${shared_modules_dir}:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules"

ssh_opts=(
  -F /dev/null
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)

label="${host%%.*}"

# Resolve the current release so it's excluded from the candidate list, then
# pick the release that many steps behind it, newest-first.
current_release="$(ssh "${ssh_opts[@]}" "root@${host}" "readlink -f '${env_dir}'" 2>/dev/null || true)"
if [ -z "$current_release" ]; then
  echo "==> ${label}: could not resolve current release (is ${env_dir} a symlink yet? run a normal apply first)" >&2
  exit 1
fi

target_release="$(ssh "${ssh_opts[@]}" "root@${host}" "
  ls -1dt '${releases_dir}'/*/ 2>/dev/null | sed 's:/*\$::' | grep -vF -- '$(basename "$current_release")'
" | sed -n "${steps_back}p")"

if [ -z "$target_release" ]; then
  echo "==> ${label}: no release ${steps_back} step(s) behind current (${current_release}) - nothing to roll back to" >&2
  exit 1
fi

echo "==> ${label}: rolling back ${current_release} -> ${target_release}"

ssh "${ssh_opts[@]}" "root@${host}" "
  set -e
  ln -sfn '${target_release}' '${env_dir}.new'
  mv -Tf '${env_dir}.new' '${env_dir}'
"

ssh "${ssh_opts[@]}" "root@${host}" "/opt/puppetlabs/bin/puppet apply --color=false --modulepath='${module_path}' --hiera_config='${env_dir}/hiera.yaml' '${env_dir}/manifests/site.pp'"
exit_code=$?

if [ "$exit_code" -eq 0 ]; then
  echo "==> ${label}: rollback apply OK - now on ${target_release}"
else
  echo "==> ${label}: rollback apply FAILED (exit ${exit_code}) - symlink already points at ${target_release}, investigate before retrying" >&2
fi
exit "$exit_code"
