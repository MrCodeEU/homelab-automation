#!/usr/bin/env bash
# Host-side half of a deploy: runs ON the target host, as root, from a
# repo-shaped tree (openvox/ and scripts/). Two callers, one apply path:
#
#   - scripts/openvox-sync.sh (laptop push, CI until the agent takes
#     over) uploads the tree and runs this over SSH;
#   - deploy-agent (docs/DEPLOY_AGENT.md) exports a verified commit and
#     runs this from the export.
#
#   openvox-apply.sh <root> <noop|apply>
#
# noop:  verify Forge modules, puppet apply --noop straight from <root>;
#        the production environment is not touched.
# apply: reconcile Forge modules, copy <root>/openvox into a new release
#        under environments/releases, point environments/production at
#        it, prune old releases, puppet apply.
#
# Environment (all optional; same meaning as in openvox-sync.sh):
#   OPENVOX_CERTNAME             --certname for puppet apply
#   OPENVOX_WEEKLY_MAINTENANCE   true: FACTER_openvox_weekly_maintenance=true
#   OPENVOX_STAGING_SERVICES     comma list: FACTER_openvox_staging_services
#   OPENVOX_RECOVERY_SERVICES    comma list: FACTER_openvox_recovery_services
#   OPENVOX_RELEASE_KEEP         releases kept (default 5)
#   OPENVOX_ENV_DIR              /tmp/openvox-pr-<n>-<m>: isolated PR/drift
#                                environment, noop only, with its own module
#                                dir; <root> is that directory's parent tree
#
# Exit status: puppet's, and 1 when its output has "Error:" lines (puppet
# apply without --detailed-exitcodes exits 0 on some resource failures).
set -uo pipefail

root="${1:?usage: openvox-apply.sh <root> <noop|apply>}"
mode="${2:?usage: openvox-apply.sh <root> <noop|apply>}"
case "$mode" in noop|apply) ;; *) echo "invalid mode: $mode" >&2; exit 2 ;; esac
root="$(cd "$root" && pwd)" || { echo "no such tree: $1" >&2; exit 2; }
src="${root}/openvox"
for f in manifests/site.pp hiera.yaml Puppetfile modules/roles modules/role data; do
  [ -e "${src}/${f}" ] || { echo "ERROR: ${src} is incomplete (missing ${f})" >&2; exit 1; }
done

env_base=/etc/puppetlabs/code/environments
env_dir="${env_base}/production"
shared_modules_dir="${env_base}/vendor-modules"
releases_dir="${env_base}/releases"
release_keep="${OPENVOX_RELEASE_KEEP:-5}"
[[ "$release_keep" =~ ^[1-9][0-9]*$ ]] || { echo "invalid OPENVOX_RELEASE_KEEP" >&2; exit 2; }

isolated=false
if [ -n "${OPENVOX_ENV_DIR:-}" ]; then
  [[ "$OPENVOX_ENV_DIR" =~ ^/tmp/openvox-pr-[0-9]+-[0-9]+$ ]] || { echo "invalid OPENVOX_ENV_DIR: $OPENVOX_ENV_DIR" >&2; exit 2; }
  [ "$mode" = noop ] || { echo "OPENVOX_ENV_DIR is noop only" >&2; exit 2; }
  isolated=true
fi

certname_arg=()
if [ -n "${OPENVOX_CERTNAME:-}" ]; then
  [[ "$OPENVOX_CERTNAME" =~ ^[a-z0-9.-]+$ ]] || { echo "invalid OPENVOX_CERTNAME" >&2; exit 2; }
  certname_arg=(--certname="$OPENVOX_CERTNAME")
fi

list_re='^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$'
facts=()
[ "${OPENVOX_WEEKLY_MAINTENANCE:-false}" = true ] && facts+=(FACTER_openvox_weekly_maintenance=true)
for pair in "STAGING:staging" "RECOVERY:recovery"; do
  var="OPENVOX_${pair%%:*}_SERVICES"
  val="${!var:-}"
  [ -n "$val" ] || continue
  [[ "$val" =~ $list_re ]] || { echo "invalid ${var}: expected comma-separated service names" >&2; exit 2; }
  facts+=("FACTER_openvox_${pair##*:}_services=${val}")
done

# One deploy at a time per host: laptop push, CI and deploy-agent all come
# through here. Isolated PR noops touch nothing shared and skip the lock.
if [ "$isolated" = false ]; then
  exec 9>/run/homelab-deploy.lock || exit 1
  flock -n 9 || { echo "ERROR: another deploy holds /run/homelab-deploy.lock" >&2; exit 1; }
fi

export OPENVOX_PUPPETFILE="${src}/Puppetfile"
cd "$root" || exit 1

# Modules: the shared vendor dir for real runs; an isolated PR run gets its
# own copy so a Puppetfile change under review cannot touch production.
if [ "$isolated" = true ]; then
  module_target="${OPENVOX_ENV_DIR}/modules"
  bash scripts/openvox-modules.sh reconcile local "$module_target" || exit 1
elif [ "$mode" = apply ]; then
  module_target="$shared_modules_dir"
  bash scripts/openvox-modules.sh reconcile local "$module_target" || exit 1
else
  module_target="$shared_modules_dir"
  bash scripts/openvox-modules.sh verify local "$module_target" || exit 1
fi

run_dir="$src"
if [ "$isolated" = true ]; then
  run_dir="$OPENVOX_ENV_DIR"
  if [ "$run_dir" != "$src" ]; then
    mkdir -p "$run_dir" && cp -a "$src"/. "$run_dir"/ || exit 1
  fi
elif [ "$mode" = apply ]; then
  release="${releases_dir}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$releases_dir" || exit 1
  [ -e "$release" ] && { echo "ERROR: release ${release} exists" >&2; exit 1; }
  # cp -a keeps the source's mtime; releases are ordered by mtime (prune
  # below, openvox-rollback.sh), so the new one must be the newest.
  cp -a "$src" "$release" && touch "$release" || exit 1
  if [ -d "$env_dir" ] && [ ! -L "$env_dir" ]; then
    mv -T "$env_dir" "${releases_dir}/pre-release-migration-$(date -u +%Y%m%dT%H%M%SZ)" || exit 1
  fi
  ln -sfn "$release" "${env_dir}.new" && mv -Tf "${env_dir}.new" "$env_dir" || exit 1
  # shellcheck disable=SC2012 # release names are timestamps, no odd characters
  ls -1dt "$releases_dir"/*/ 2>/dev/null | tail -n +$((release_keep + 1)) | xargs -r rm -rf --
  run_dir="$env_dir"
fi

noop_arg=()
[ "$mode" = noop ] && noop_arg=(--noop)
module_path="${run_dir}/modules:${module_target}:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
env "${facts[@]}" /opt/puppetlabs/bin/puppet apply "${certname_arg[@]}" --color=false "${noop_arg[@]}" \
  --modulepath="$module_path" --hiera_config="${run_dir}/hiera.yaml" "${run_dir}/manifests/site.pp" 2>&1 | tee "$out"
rc="${PIPESTATUS[0]}"
if [ "$rc" -eq 0 ] && grep -qE '^Error:' "$out"; then
  rc=1
fi
exit "$rc"
