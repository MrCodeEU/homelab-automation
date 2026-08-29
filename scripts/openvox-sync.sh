#!/usr/bin/env bash
# Remote paths and commands below are deliberately constructed from validated
# client-side values.
# shellcheck disable=SC2029
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
# $weekly_maintenance fact read. OPENVOX_STAGING_SERVICES is an optional,
# comma-separated catalog selection that explicitly deploys staging instances
# on nuc; normal applies deliberately leave those containers alone.
# OPENVOX_RECOVERY_SERVICES is a separate, explicit fresh-host-only selection.
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

# Releases live at sibling releases/<timestamp>/ next to env_dir, e.g.
# /etc/puppetlabs/code/environments/releases/20260829T101500Z. `production`
# (env_dir) is kept as a symlink to the current release so a real apply can
# ln -sfn to a new release atomically (see below) and openvox-rollback.sh can
# point it back at a previous one without re-syncing anything. Noop/isolated
# runs never touch this - they sync straight into env_dir as before, since
# they're read-only checks, not a real deploy.
env_base="$(dirname "$env_dir")"
releases_dir="${env_base}/releases"
release_keep="${OPENVOX_RELEASE_KEEP:-5}"
use_release=false
if [ "$isolated_env" = false ] && [ "$mode" = "apply" ]; then
  use_release=true
fi

# Forge modules (stdlib, apt, docker, ...) are pinned by Puppetfile, not by a
# given release - they live in a persistent shared dir, sibling to env_dir,
# instead of inside a per-release directory. Otherwise every release swap
# would need a full forge reinstall, and releases/ would balloon in size.
# `roles` (this repo's own code) is the thing that actually changes release
# to release, so it stays inside env_dir (the release currently symlinked).
shared_modules_dir="${env_base}/vendor-modules"
module_target="${env_dir}/modules"
if [ "$isolated_env" = false ]; then
  module_target="$shared_modules_dir"
fi
module_path="${env_dir}/modules:${shared_modules_dir}:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules"

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
  -o ControlMaster=auto
  -o ControlPersist=5
  -o ControlPath=/tmp/openvox-ssh-%C
)
facter_prefix=""
if [ "${OPENVOX_WEEKLY_MAINTENANCE:-false}" = "true" ]; then
  facter_prefix="FACTER_openvox_weekly_maintenance=true "
fi

staging_services="${OPENVOX_STAGING_SERVICES:-}"
if [ -n "$staging_services" ]; then
  # This value is interpolated into the remote command as a Facter value. Keep
  # its grammar deliberately narrower than service names in general so a
  # workflow input cannot inject shell syntax on the privileged SSH target.
  if [[ ! "$staging_services" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then
    echo "invalid OPENVOX_STAGING_SERVICES: expected comma-separated service names" >&2
    exit 2
  fi
  facter_prefix+="FACTER_openvox_staging_services=${staging_services} "
fi

recovery_services="${OPENVOX_RECOVERY_SERVICES:-}"
if [ -n "$recovery_services" ]; then
  if [[ ! "$recovery_services" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then
    echo "invalid OPENVOX_RECOVERY_SERVICES: expected comma-separated service names" >&2
    exit 2
  fi
  facter_prefix+="FACTER_openvox_recovery_services=${recovery_services} "
fi

# Short label for prefixing/log naming, e.g. "mljr.tail33930.ts.net" -> "mljr".
label="${host%%.*}"

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
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
  # Candidate PR dependencies go into the isolated environment. Production
  # noops stay read-only; applies reconcile the pinned dependency set first.
  if [ "$isolated_env" = true ] || [ "$mode" = apply ]; then
    ./scripts/openvox-modules.sh reconcile "$host" "$module_target"
  else
    ./scripts/openvox-modules.sh verify "$host" "$module_target"
  fi

  xfer_dir="$env_dir"
  if [ "$use_release" = true ]; then
    release_ts="$(date -u +%Y%m%dT%H%M%SZ)"
    xfer_dir="${releases_dir}/${release_ts}"
  fi

  ssh "${ssh_opts[@]}" "root@${host}" "mkdir -p ${xfer_dir}/manifests ${xfer_dir}/modules/roles ${xfer_dir}/modules/role ${xfer_dir}/data"

  if [ "${host}" = "ugreen.tail33930.ts.net" ]; then
    scp -rq "${ssh_opts[@]}" openvox/manifests/. "root@${host}:${xfer_dir}/manifests/"
    scp -rq "${ssh_opts[@]}" openvox/modules/roles/. "root@${host}:${xfer_dir}/modules/roles/"
    scp -rq "${ssh_opts[@]}" openvox/modules/role/. "root@${host}:${xfer_dir}/modules/role/"
    scp -q "${ssh_opts[@]}" openvox/hiera.yaml "root@${host}:${xfer_dir}/hiera.yaml"
    scp -rq "${ssh_opts[@]}" openvox/data/. "root@${host}:${xfer_dir}/data/"
  else
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/manifests/ "root@${host}:${xfer_dir}/manifests/"
    rsync -az --delete -e "ssh ${ssh_opts[*]}" openvox/modules/roles/ "root@${host}:${xfer_dir}/modules/roles/"
    rsync -az --delete -e "ssh ${ssh_opts[*]}" openvox/modules/role/ "root@${host}:${xfer_dir}/modules/role/"
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/hiera.yaml "root@${host}:${xfer_dir}/hiera.yaml"
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/data/ "root@${host}:${xfer_dir}/data/"
  fi

  if [ "$use_release" = true ]; then
    # Atomic swap: build the symlink under a temp name, then rename it over
    # env_dir in one syscall - env_dir is never briefly missing or partial.
    # First-ever run: env_dir may still be a real directory from before this
    # release scheme existed - move it into releases/ so it becomes a valid
    # rollback target instead of just being clobbered by the symlink.
    ssh "${ssh_opts[@]}" "root@${host}" "
      set -e
      mkdir -p '${releases_dir}'
      if [ -d '${env_dir}' ] && [ ! -L '${env_dir}' ]; then
        mv -T '${env_dir}' '${releases_dir}/pre-release-migration-$(date -u +%Y%m%dT%H%M%SZ)'
      fi
      ln -sfn '${xfer_dir}' '${env_dir}.new'
      mv -Tf '${env_dir}.new' '${env_dir}'
      ls -1dt '${releases_dir}'/*/ 2>/dev/null | tail -n +$((release_keep + 1)) | xargs -r rm -rf --
    "
  fi

  if [ "${mode}" = "apply" ]; then
    ssh "${ssh_opts[@]}" "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply --color=false --modulepath='${module_path}' --hiera_config='${env_dir}/hiera.yaml' '${env_dir}/manifests/site.pp'"
  else
    ssh "${ssh_opts[@]}" "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply --color=false --noop --modulepath='${module_path}' --hiera_config='${env_dir}/hiera.yaml' '${env_dir}/manifests/site.pp'"
  fi
} 2>&1 | tee "$log_file" | prefix
exit_code="${PIPESTATUS[0]}"

elapsed=$(( $(date +%s) - start_epoch ))

changed=$(grep -cE "/(ensure|content|returns|mode|owner|group):" "$log_file" 2>/dev/null || true)
errors=$(grep -cE "^Error:" "$log_file" 2>/dev/null || true)
if [ "${errors:-0}" -gt 0 ]; then
  # `puppet apply` can return zero even when individual resources fail unless
  # detailed exit codes are requested. Never let a logged Puppet error become
  # a green host result or successful deployment workflow.
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "${c_bold}==> ${label}${c_green} OK${c_reset} (${mode}, ${elapsed}s) - log: ${log_file}" | prefix
else
  echo "${c_bold}==> ${label}${c_red} FAILED${c_reset} (${mode}, exit ${exit_code}, ${elapsed}s) - log: ${log_file}" | prefix
fi

if [ "${errors:-0}" -gt 0 ]; then
  echo "${c_yellow}==> ${label}: ${errors} error line(s):${c_reset}" | prefix
  grep -E "^Error:" "$log_file" | prefix
fi
echo "==> ${label}: ${changed:-0} resource change line(s), ${errors:-0} error line(s)" | prefix

exit "$exit_code"
