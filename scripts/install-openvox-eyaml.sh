#!/usr/bin/env bash
# Installs the hiera-eyaml gem into OpenVox's bundled Ruby and deploys the
# PKCS7 decrypt key pair to a host that needs to consume roles::* secrets
# via lookup('vault_...'). Deliberately a separate, explicit step per
# host - not part of openvox-sync.sh's general environment sync, which
# runs against every host in the fleet. The private key must exist on
# every host that needs to decrypt a given secret (masterless setup, no
# puppetserver to act as a single unlock point), but that's a decision to
# make per host/per secret, not something that should happen implicitly
# just because a host is in the fleet.
set -euo pipefail

host="${1:?usage: install-openvox-eyaml.sh <ssh-target>}"
key_dir=/etc/puppetlabs/puppet/eyaml

ssh "root@${host}" "
  set -euo pipefail
  if ! /opt/puppetlabs/puppet/bin/gem list -i hiera-eyaml >/dev/null 2>&1; then
    /opt/puppetlabs/puppet/bin/gem install hiera-eyaml --no-document
  fi
  mkdir -p ${key_dir}
  chmod 700 ${key_dir}
"

scp -q openvox/keys/private_key.pkcs7.pem "root@${host}:${key_dir}/private_key.pkcs7.pem"
scp -q openvox/keys/public_key.pkcs7.pem "root@${host}:${key_dir}/public_key.pkcs7.pem"

ssh "root@${host}" "
  chown root:root ${key_dir}/private_key.pkcs7.pem ${key_dir}/public_key.pkcs7.pem
  chmod 400 ${key_dir}/private_key.pkcs7.pem
  chmod 444 ${key_dir}/public_key.pkcs7.pem
  echo 'eyaml key pair installed at ${key_dir}'
"
