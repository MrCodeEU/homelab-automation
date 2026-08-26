#!/usr/bin/env bash
# Syncs openvox/manifests + openvox/modules/roles + hiera.yaml + data/
# (encrypted eyaml data only - decrypt keys are deployed separately, see
# scripts/install-openvox-eyaml.sh) to a target host, then runs
# `puppet apply` (--noop unless $2 is "apply").
#
# ugreen (UGOS) blocks rsync's --server mode entirely - same known
# constraint that forced the old Ansible role onto plain file copy for
# that host too (see ansible/roles/services/tasks/prepare_service.yml).
# scp -r works fine there; rsync is used everywhere else for its
# incremental-diff speed.
#
# OPENVOX_WEEKLY_MAINTENANCE=true (env, not an arg - CI's own weekly
# schedule sets this) forwards FACTER_openvox_weekly_maintenance=true to
# the remote `puppet apply`, the masterless equivalent of Ansible's
# docker_prune_enabled/reboot_if_needed extra-vars - see site.pp's own
# $weekly_maintenance fact read.
#
# Every line of remote output is prefixed with the host's short label
# (e.g. "[mljr]") - this is the main readability fix over the old plain
# passthrough, since `make openvox-check`/`openvox-deploy` run all hosts
# in parallel via xargs -P4 and their raw output used to interleave with
# no way to tell which host a given line came from. The full raw log
# (unprefixed, exactly what the remote commands printed) is also saved
# to logs/openvox/ for later inspection - *.log is already gitignored.
set -uo pipefail

host="${1:?usage: openvox-sync.sh <ssh-target> [apply]}"
mode="${2:-noop}"
env_dir="${OPENVOX_ENV_DIR:-/etc/puppetlabs/code/environments/production}"

# PR checks use a per-run tree under /tmp so proposed code never replaces the
# live production environment. Keep the override deliberately narrow: this
# variable reaches root SSH commands and must never accept a general path.
isolated_env=false
if [ -n "${OPENVOX_ENV_DIR:-}" ]; then
  if [[ ! "$env_dir" =~ ^/tmp/openvox-pr-[0-9]+-[0-9]+$ ]]; then
    echo "invalid OPENVOX_ENV_DIR: $env_dir" >&2
    exit 2
  fi
  isolated_env=true
fi
# Third-party modules were installed into the production environment by the
# original bootstrap script. Proposed `roles` code must win, while those pinned
# host-local dependencies remain available to compile the isolated catalog.
module_path="${env_dir}/modules:/etc/puppetlabs/code/environments/production/modules:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules"

# accept-new (not the no-op "no"): trusts a host's key on first contact and
# persists it, but still refuses a key that later CHANGES. Needed because a
# fresh CI runner has no known_hosts entries at all for this tailnet, unlike
# a dev machine that's already SSH'd into these hosts before.
# Deployment addressing and authentication are explicit; do not inherit an
# operator workstation's ProxyCommand/Host overrides (or fail because an
# unrelated system SSH fragment has unsafe ownership/mode).
ssh_opts=(
  -F /dev/null
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)
facter_prefix=""
if [ "${OPENVOX_WEEKLY_MAINTENANCE:-false}" = "true" ]; then
  facter_prefix="FACTER_openvox_weekly_maintenance=true "
fi

# Short label for prefixing/log naming, e.g. "mljr.tail33930.ts.net" -> "mljr".
label="${host%%.*}"

cleanup_isolated_env() {
  if [ "$isolated_env" = true ]; then
    ssh "${ssh_opts[@]}" "root@${host}" "rm -rf -- '${env_dir}'" >/dev/null 2>&1 || true
  fi
}
trap cleanup_isolated_env EXIT

if [ -t 1 ]; then
  c_bold=$'\033[1m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_reset=$'\033[0m'
else
  c_bold=""; c_green=""; c_red=""; c_yellow=""; c_reset=""
fi

log_dir="logs/openvox"
mkdir -p "$log_dir"
log_file="${log_dir}/${label}-${mode}-$(date -u +%Y%m%dT%H%M%SZ).log"

prefix() {
  sed -u "s/^/[${label}] /"
}

start_epoch=$(date +%s)
echo "${c_bold}==> ${label}${c_reset} (${mode}) starting..." | prefix

{
  ssh "${ssh_opts[@]}" "root@${host}" "mkdir -p ${env_dir}/manifests ${env_dir}/modules/roles ${env_dir}/data"

  if [ "${host}" = "ugreen.tail33930.ts.net" ]; then
    scp -rq "${ssh_opts[@]}" openvox/manifests/. "root@${host}:${env_dir}/manifests/"
    scp -rq "${ssh_opts[@]}" openvox/modules/roles/. "root@${host}:${env_dir}/modules/roles/"
    scp -q "${ssh_opts[@]}" openvox/hiera.yaml "root@${host}:${env_dir}/hiera.yaml"
    scp -rq "${ssh_opts[@]}" openvox/data/. "root@${host}:${env_dir}/data/"
  else
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/manifests/ "root@${host}:${env_dir}/manifests/"
    rsync -az --delete -e "ssh ${ssh_opts[*]}" openvox/modules/roles/ "root@${host}:${env_dir}/modules/roles/"
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/hiera.yaml "root@${host}:${env_dir}/hiera.yaml"
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/data/ "root@${host}:${env_dir}/data/"
  fi

  if [ "${mode}" = "apply" ]; then
    ssh "${ssh_opts[@]}" "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply --color=false --modulepath='${module_path}' --hiera_config='${env_dir}/hiera.yaml' '${env_dir}/manifests/site.pp'"
  else
    ssh "${ssh_opts[@]}" "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply --color=false --noop --modulepath='${module_path}' --hiera_config='${env_dir}/hiera.yaml' '${env_dir}/manifests/site.pp'"
  fi
} 2>&1 | tee "$log_file" | prefix
exit_code="${PIPESTATUS[0]}"

elapsed=$(( $(date +%s) - start_epoch ))

if [ "$exit_code" -eq 0 ]; then
  echo "${c_bold}==> ${label}${c_green} OK${c_reset} (${mode}, ${elapsed}s) - log: ${log_file}" | prefix
else
  echo "${c_bold}==> ${label}${c_red} FAILED${c_reset} (${mode}, exit ${exit_code}, ${elapsed}s) - log: ${log_file}" | prefix
fi

changed=$(grep -cE "/(ensure|content|returns|mode|owner|group):" "$log_file" 2>/dev/null || true)
errors=$(grep -cE "^Error:" "$log_file" 2>/dev/null || true)
if [ "${errors:-0}" -gt 0 ]; then
  echo "${c_yellow}==> ${label}: ${errors} error line(s):${c_reset}" | prefix
  grep -E "^Error:" "$log_file" | prefix
fi
echo "==> ${label}: ${changed:-0} resource change line(s), ${errors:-0} error line(s)" | prefix

exit "$exit_code"
