#!/usr/bin/env bash
# Installs the OpenVox agent (Puppet fork, Apache-2.0, Vox Pupuli-governed)
# on a Rocky Linux host. Picks the el9/el10 release package by the
# target's own OS - the two rocky hosts are on different major versions
# (mljr: 9.8, nuc: 10.2) and the bundled Ruby runtime is
# glibc-version-specific, so the wrong package fails at runtime, not at
# install time (confirmed live: el10 package installs "successfully" on
# an el9 host, then every puppet invocation fails with GLIBC_2.38/2.35
# not found).
#
# certname is pinned explicitly to the tailnet FQDN passed as $1 - Puppet
# defaults node-matching to the machine's real OS hostname, which for a
# cloud VPS (mljr) is the provider's default (e.g.
# vmi2945702.contaboserver.net), not anything meaningful here. Ansible
# never had this problem since it always addressed hosts by inventory
# name over SSH, never by asking the host what it thinks its own name is.
set -euo pipefail

host="${1:?usage: install-openvox.sh <ssh-target>}"

ssh "root@${host}" "
  set -euo pipefail
  if command -v /opt/puppetlabs/bin/puppet >/dev/null 2>&1; then
    echo 'openvox-agent already installed: '\$(/opt/puppetlabs/bin/puppet --version)
  else
    el_major=\$(rpm -E %{rhel})
    dnf install -y \"https://yum.voxpupuli.org/openvox8-release-el-\${el_major}.noarch.rpm\"
    dnf install -y openvox-agent
    /opt/puppetlabs/bin/puppet module install puppet-firewalld
    /opt/puppetlabs/bin/puppet module install puppetlabs-docker
  fi
  mkdir -p /etc/puppetlabs/puppet
  /opt/puppetlabs/bin/puppet config set certname '${host}' --section main
  echo \"certname: \$(/opt/puppetlabs/bin/puppet config print certname)\"
"
