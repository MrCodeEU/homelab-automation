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
set -euo pipefail

host="${1:?usage: openvox-sync.sh <ssh-target> [apply]}"
mode="${2:-noop}"
env_dir="/etc/puppetlabs/code/environments/production"
facter_prefix=""
if [ "${OPENVOX_WEEKLY_MAINTENANCE:-false}" = "true" ]; then
  facter_prefix="FACTER_openvox_weekly_maintenance=true "
fi

ssh "root@${host}" "mkdir -p ${env_dir}/manifests ${env_dir}/modules/roles ${env_dir}/data"

if [ "${host}" = "ugreen.tail33930.ts.net" ]; then
  scp -rq openvox/manifests/. "root@${host}:${env_dir}/manifests/"
  scp -rq openvox/modules/roles/. "root@${host}:${env_dir}/modules/roles/"
  scp -q openvox/hiera.yaml "root@${host}:${env_dir}/hiera.yaml"
  scp -rq openvox/data/. "root@${host}:${env_dir}/data/"
else
  rsync -az openvox/manifests/ "root@${host}:${env_dir}/manifests/"
  rsync -az --delete openvox/modules/roles/ "root@${host}:${env_dir}/modules/roles/"
  rsync -az openvox/hiera.yaml "root@${host}:${env_dir}/hiera.yaml"
  rsync -az openvox/data/ "root@${host}:${env_dir}/data/"
fi

if [ "${mode}" = "apply" ]; then
  ssh "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply ${env_dir}/manifests/site.pp"
else
  ssh "root@${host}" "${facter_prefix}/opt/puppetlabs/bin/puppet apply --noop ${env_dir}/manifests/site.pp"
fi
