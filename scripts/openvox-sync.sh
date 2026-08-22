#!/usr/bin/env bash
# Syncs openvox/manifests + openvox/modules/roles to a target host, then
# runs `puppet apply` (--noop unless $2 is "apply").
#
# ugreen (UGOS) blocks rsync's --server mode entirely - same known
# constraint that forced the old Ansible role onto plain file copy for
# that host too (see ansible/roles/services/tasks/prepare_service.yml).
# scp -r works fine there; rsync is used everywhere else for its
# incremental-diff speed.
set -euo pipefail

host="${1:?usage: openvox-sync.sh <ssh-target> [apply]}"
mode="${2:-noop}"
env_dir="/etc/puppetlabs/code/environments/production"

ssh "root@${host}" "mkdir -p ${env_dir}/manifests ${env_dir}/modules/roles"

if [ "${host}" = "ugreen.tail33930.ts.net" ]; then
  scp -rq openvox/manifests/. "root@${host}:${env_dir}/manifests/"
  scp -rq openvox/modules/roles/. "root@${host}:${env_dir}/modules/roles/"
else
  rsync -az openvox/manifests/ "root@${host}:${env_dir}/manifests/"
  rsync -az --delete openvox/modules/roles/ "root@${host}:${env_dir}/modules/roles/"
fi

if [ "${mode}" = "apply" ]; then
  ssh "root@${host}" "/opt/puppetlabs/bin/puppet apply ${env_dir}/manifests/site.pp"
else
  ssh "root@${host}" "/opt/puppetlabs/bin/puppet apply --noop ${env_dir}/manifests/site.pp"
fi
