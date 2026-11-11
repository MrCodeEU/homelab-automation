#!/bin/bash
# push.sh <vm> [apply]: rsync this dir to the VM over Ziti and run
# puppet apply there (--noop unless "apply"). The spike's openvox-sync.sh.
set -euo pipefail
vm=$1
mode=${2:-noop}
here=$(cd "$(dirname "$0")" && pwd)
cfg=${SPIKE_SSH_CONFIG:?set SPIKE_SSH_CONFIG}
noop=--noop
[ "$mode" = apply ] && noop=
rsync -az --delete -e "ssh -F $cfg" --exclude push.sh "$here/" "$vm:/etc/puppetlabs/code/spike/"
ssh -F "$cfg" "$vm" "cd /etc/puppetlabs/code/spike && /opt/puppetlabs/bin/puppet apply $noop --detailed-exitcodes \
  --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp"
