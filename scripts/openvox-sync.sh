#!/usr/bin/env bash
# Remote paths and commands below are deliberately constructed from validated
# client-side values.
# shellcheck disable=SC2029
# Syncs openvox/manifests + openvox/modules/roles + hiera.yaml + data/
# (encrypted eyaml data only - decrypt keys are deployed separately, see
# scripts/install-openvox-eyaml.sh) + Puppetfile and the host-side scripts
# to a staging tree on the target host, then runs scripts/openvox-apply.sh
# there (--noop unless $2 is "apply"). openvox-apply.sh does the rest
# (Forge modules, release + symlink swap, puppet apply); deploy-agent runs
# the same script from a verified commit (docs/DEPLOY_AGENT.md).
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

# Puppet identity (certname) is decoupled from the SSH transport above
# (Phase 2, docs/ZERO_TRUST_PLAN.md): a migrated host still connects over its
# Tailscale name but applies under its <host>.int.mljr.eu certname, which
# drives its hiera node file, eyaml secrets file and eyaml key dir. Hosts not
# listed here keep using their on-host default certname (no --certname),
# so the migration rolls out one host at a time with per-host rollback.
case "$host" in
  mljr.tail33930.ts.net)   certname='mljr.int.mljr.eu' ;;
  nuc.tail33930.ts.net)    certname='nuc.int.mljr.eu' ;;
  ugreen.tail33930.ts.net) certname='ugreen.int.mljr.eu' ;;
  *)                       certname='' ;;
esac

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

# The staging tree is repo-shaped (openvox/, scripts/) and persistent, so
# rsync stays incremental; openvox-apply.sh copies it into a new release.
# Isolated runs stage under their own /tmp dir, removed on exit.
stage_dir=/var/lib/openvox-push
if [ "$isolated_env" = true ]; then
  stage_dir="${env_dir}/tree"
fi

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
  -o ConnectionAttempts=3
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=5
  -o ControlPath=/tmp/openvox-ssh-%C
)
# Passed to openvox-apply.sh, which turns them into FACTER_ values.
apply_env=""
if [ "${OPENVOX_WEEKLY_MAINTENANCE:-false}" = "true" ]; then
  apply_env="OPENVOX_WEEKLY_MAINTENANCE=true "
fi
[ -n "$certname" ] && apply_env+="OPENVOX_CERTNAME=${certname} "
[ "$isolated_env" = true ] && apply_env+="OPENVOX_ENV_DIR=${env_dir} "
[ -n "${OPENVOX_RELEASE_KEEP:-}" ] && [[ "$OPENVOX_RELEASE_KEEP" =~ ^[1-9][0-9]*$ ]] && apply_env+="OPENVOX_RELEASE_KEEP=${OPENVOX_RELEASE_KEEP} "

staging_services="${OPENVOX_STAGING_SERVICES:-}"
if [ -n "$staging_services" ]; then
  # This value is interpolated into the remote command as an env value. Keep
  # its grammar deliberately narrower than service names in general so a
  # workflow input cannot inject shell syntax on the privileged SSH target.
  if [[ ! "$staging_services" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then
    echo "invalid OPENVOX_STAGING_SERVICES: expected comma-separated service names" >&2
    exit 2
  fi
  apply_env+="OPENVOX_STAGING_SERVICES=${staging_services} "
fi

recovery_services="${OPENVOX_RECOVERY_SERVICES:-}"
if [ -n "$recovery_services" ]; then
  if [[ ! "$recovery_services" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then
    echo "invalid OPENVOX_RECOVERY_SERVICES: expected comma-separated service names" >&2
    exit 2
  fi
  apply_env+="OPENVOX_RECOVERY_SERVICES=${recovery_services} "
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
  # Every step must succeed. This block has no `set -e`, and a transient SSH
  # timeout once let a release swap point `production` at a directory that
  # was never created (2026-10-19, mljr); the swap now happens on the host,
  # after the copy, in openvox-apply.sh.
  ssh "${ssh_opts[@]}" "root@${host}" "mkdir -p ${stage_dir}/openvox/manifests ${stage_dir}/openvox/modules/roles ${stage_dir}/openvox/modules/role ${stage_dir}/openvox/data ${stage_dir}/scripts" \
    || { echo "ERROR: could not create ${stage_dir} on ${host}" >&2; exit 1; }

  if [ "${host}" = "ugreen.tail33930.ts.net" ]; then
    # No rsync on UGOS (see above). scp does not delete: start from an
    # empty tree, so a removed file does not linger.
    ssh "${ssh_opts[@]}" "root@${host}" "rm -rf -- ${stage_dir}/openvox && mkdir -p ${stage_dir}/openvox/manifests ${stage_dir}/openvox/modules/roles ${stage_dir}/openvox/modules/role ${stage_dir}/openvox/data" \
      || { echo "ERROR: could not reset ${stage_dir} on ${host}" >&2; exit 1; }
    for d in manifests modules/roles modules/role data; do
      scp -rq "${ssh_opts[@]}" "openvox/${d}/." "root@${host}:${stage_dir}/openvox/${d}/" \
        || { echo "ERROR: transfer to ${host} failed: scp" >&2; exit 1; }
    done
    scp -q "${ssh_opts[@]}" openvox/hiera.yaml openvox/Puppetfile "root@${host}:${stage_dir}/openvox/" \
      || { echo "ERROR: transfer to ${host} failed: scp" >&2; exit 1; }
    scp -q "${ssh_opts[@]}" scripts/openvox-apply.sh scripts/openvox-modules.sh "root@${host}:${stage_dir}/scripts/" \
      || { echo "ERROR: transfer to ${host} failed: scp" >&2; exit 1; }
  else
    for d in manifests modules/roles modules/role data; do
      rsync -az --delete -e "ssh ${ssh_opts[*]}" "openvox/${d}/" "root@${host}:${stage_dir}/openvox/${d}/" \
        || { echo "ERROR: transfer to ${host} failed: rsync" >&2; exit 1; }
    done
    rsync -az -e "ssh ${ssh_opts[*]}" openvox/hiera.yaml openvox/Puppetfile "root@${host}:${stage_dir}/openvox/" \
      || { echo "ERROR: transfer to ${host} failed: rsync" >&2; exit 1; }
    rsync -az -e "ssh ${ssh_opts[*]}" scripts/openvox-apply.sh scripts/openvox-modules.sh "root@${host}:${stage_dir}/scripts/" \
      || { echo "ERROR: transfer to ${host} failed: rsync" >&2; exit 1; }
  fi

  ssh "${ssh_opts[@]}" "root@${host}" "${apply_env}bash '${stage_dir}/scripts/openvox-apply.sh' '${stage_dir}' '${mode}'"
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
