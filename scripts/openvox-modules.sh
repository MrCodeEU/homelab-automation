#!/usr/bin/env bash
# Validate or reconcile the exact Forge module versions in openvox/Puppetfile.
# Remote commands interpolate only values constrained by the allowlists below.
# shellcheck disable=SC2029
set -euo pipefail

action="${1:?usage: openvox-modules.sh <validate|verify|reconcile> [ssh-target] [module-dir]}"
host="${2:-}"
module_dir="${3:-/etc/puppetlabs/code/environments/vendor-modules}"
puppetfile="openvox/Puppetfile"

case "$action" in
  validate) ;;
  verify|reconcile)
    [ -n "$host" ] || { echo "missing ssh target" >&2; exit 2; }
    [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "invalid ssh target: $host" >&2; exit 2; }
    [[ "$module_dir" == /etc/puppetlabs/code/environments/vendor-modules ]] ||
      [[ "$module_dir" =~ ^/tmp/openvox-pr-[0-9]+-[0-9]+/modules$ ]] || {
      echo "invalid module directory: $module_dir" >&2
      exit 2
    }
    ;;
  *) echo "invalid action: $action" >&2; exit 2 ;;
esac

mapfile -t modules < <(
  sed -nE "s/^[[:space:]]*mod[[:space:]]+'([a-zA-Z0-9_-]+\/[a-zA-Z0-9_-]+)',[[:space:]]*'([0-9]+\.[0-9]+\.[0-9]+)'[[:space:]]*$/\1 \2/p" "$puppetfile"
)

[ "${#modules[@]}" -gt 0 ] || { echo "no modules found in $puppetfile" >&2; exit 1; }
if [ "$(printf '%s\n' "${modules[@]}" | cut -d' ' -f1 | sort | uniq -d | wc -l)" -ne 0 ]; then
  echo "duplicate module in $puppetfile" >&2
  exit 1
fi

# Every non-comment module declaration must match the intentionally narrow,
# Renovate-compatible format parsed above.
declared_count=$(grep -cE "^[[:space:]]*mod[[:space:]]+" "$puppetfile")
[ "$declared_count" -eq "${#modules[@]}" ] || {
  echo "unsupported module declaration in $puppetfile" >&2
  exit 1
}

if [ "$action" = validate ]; then
  printf 'validated %d pinned OpenVox modules\n' "${#modules[@]}"
  exit 0
fi

ssh_opts=(
  -F /dev/null
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=5
  -o ControlPath=/tmp/openvox-ssh-%C
)

# puppet/firewalld was replaced by roles::firewalld. Remove only that known,
# obsolete module on reconciliation; never prune arbitrary operator modules.
if [ "$action" = reconcile ]; then
  ssh "${ssh_opts[@]}" "root@${host}" "rm -rf -- '$module_dir/firewalld'"
fi
ssh "${ssh_opts[@]}" "root@${host}" "mkdir -p '$module_dir'"

# Seed all cached modules before taking the one installed-version inventory.
if [[ "$module_dir" == /tmp/openvox-pr-*/modules ]]; then
  for entry in "${modules[@]}"; do
    module=${entry%% *}
    short_name=${module#*/}
    ssh "${ssh_opts[@]}" "root@${host}" \
      "if [ ! -e '$module_dir/$short_name' ] && [ -d '/etc/puppetlabs/code/environments/vendor-modules/$short_name' ]; then cp -a '/etc/puppetlabs/code/environments/vendor-modules/$short_name' '$module_dir/'; fi"
  done
fi

installed=$(ssh "${ssh_opts[@]}" "root@${host}" \
  "/opt/puppetlabs/bin/puppet module list --color=false --modulepath='$module_dir'")

for entry in "${modules[@]}"; do
  module=${entry%% *}
  version=${entry##* }
  expected="${module//\//-} (v${version})"

  if grep -Fq -- "$expected" <<< "$installed"; then
    echo "${host%%.*}: $module $version already installed"
    continue
  fi

  if [ "$action" = verify ]; then
    echo "${host%%.*}: expected $module $version in $module_dir" >&2
    exit 1
  fi

  echo "${host%%.*}: installing $module $version"
  # Dependencies are all explicitly pinned above. Ignoring automatic dependency
  # installation prevents the Forge resolver from reintroducing version drift.
  ssh "${ssh_opts[@]}" "root@${host}" \
    "/opt/puppetlabs/bin/puppet module install '$module' --version='$version' --target-dir='$module_dir' --force --ignore-dependencies"
done

# This reports missing or incompatible transitive dependencies after all exact
# versions are present. Its non-zero status makes dependency-update PRs fail.
installed=$(ssh "${ssh_opts[@]}" "root@${host}" \
  "/opt/puppetlabs/bin/puppet module list --color=false --modulepath='$module_dir'")
printf '%s\n' "$installed"
for entry in "${modules[@]}"; do
  module=${entry%% *}
  version=${entry##* }
  expected="${module//\//-} (v${version})"
  grep -Fq -- "$expected" <<< "$installed" || {
    echo "${host%%.*}: failed to install $module $version" >&2
    exit 1
  }
done
