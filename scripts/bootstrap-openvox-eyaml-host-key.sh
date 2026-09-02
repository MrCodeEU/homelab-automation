#!/usr/bin/env bash
# Create a host-specific hiera-eyaml PKCS7 pair. The private key is generated
# and retained on the destination host; this script retrieves only its public
# half for review and use by the ciphertext migration tool.
set -euo pipefail

usage() {
  echo "usage: $0 <mljr|nuc|ugreen>" >&2
  exit 2
}

host="${1:-}"
case "$host" in
  mljr|mljr.tail33930.ts.net) canonical_host='mljr.tail33930.ts.net'; key_name='mljr'; certname='mljr.tail33930.ts.net' ;;
  nuc|nuc.tail33930.ts.net) canonical_host='nuc.tail33930.ts.net'; key_name='nuc'; certname='nuc.tail33930.ts.net' ;;
  ugreen|ugreen.tail33930.ts.net) canonical_host='ugreen.tail33930.ts.net'; key_name='ugreen'; certname='ugreen.tail33930.ts.net' ;;
  *) usage ;;
esac

remote_key_dir="/etc/puppetlabs/puppet/eyaml/hosts/${certname}"
public_key="${remote_key_dir}/public_key.pkcs7.pem"
private_key="${remote_key_dir}/private_key.pkcs7.pem"
local_public_key="openvox/keys/${key_name}/public_key.pkcs7.pem"
tmp_public_key="$(mktemp)"
trap 'rm -f "$tmp_public_key"' EXIT

ssh "root@${canonical_host}" "
  set -euo pipefail
  eyaml=/opt/puppetlabs/puppet/bin/eyaml
  gem=/opt/puppetlabs/puppet/bin/gem
  if ! \"\$gem\" list -i hiera-eyaml >/dev/null 2>&1; then
    \"\$gem\" install hiera-eyaml --no-document
  fi
  install -d -m 0700 '${remote_key_dir}'
  if [ ! -f '${private_key}' ]; then
    \"\$eyaml\" createkeys --pkcs7-private-key='${private_key}' --pkcs7-public-key='${public_key}'
  fi
  test -s '${private_key}'
  test -s '${public_key}'
  chown root:root '${private_key}' '${public_key}'
  chmod 0400 '${private_key}'
  chmod 0444 '${public_key}'
"

scp -q "root@${canonical_host}:${public_key}" "$tmp_public_key"
install -D -m 0644 "$tmp_public_key" "$local_public_key"
echo "Created ${key_name}'s private key on ${canonical_host}; saved public key to ${local_public_key}."
