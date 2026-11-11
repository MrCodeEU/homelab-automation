#!/bin/sh
# Host-side apply for the deploy-agent prototype: runs from the tree root.
set -eu
cd spike/openvox
noop=
[ "${DEPLOY_MODE:-apply}" = noop ] && noop=--noop
rc=0
/opt/puppetlabs/bin/puppet apply $noop --detailed-exitcodes --modulepath=modules --hiera_config=hiera.yaml manifests/site.pp || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 2 ]
