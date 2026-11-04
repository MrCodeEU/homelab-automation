#!/usr/bin/env bash
# Print one decrypted value from a host's eyaml file. Decrypts on the host with
# its own key; plaintext goes to stdout only, nothing is written to disk on
# either side. Never pipe the output into a log or a commit.
# usage: eyaml-get.sh <mljr|nuc|ugreen> [key]   (no key = list key names)
set -euo pipefail

host="${1:-}"
key="${2:-}"
# Puppet certname (identity: names the secrets file and on-host key dir) is
# decoupled from the SSH transport for migrated hosts (Phase 2,
# docs/ZERO_TRUST_PLAN.md); transport stays Tailscale until the OpenZiti phase.
case "$host" in
  mljr)   cert="mljr.tail33930.ts.net";   ssh_target="mljr.tail33930.ts.net" ;;
  nuc)    cert="nuc.int.mljr.eu";         ssh_target="nuc.tail33930.ts.net" ;;
  ugreen) cert="ugreen.tail33930.ts.net"; ssh_target="ugreen.tail33930.ts.net" ;;
  *) echo "usage: $0 <mljr|nuc|ugreen> [key]" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="${repo}/openvox/data/secrets/${cert}.eyaml"
[[ -f "$file" ]] || { echo "missing $file" >&2; exit 1; }

if [[ -z "$key" ]]; then
  grep -oE '^"?[A-Za-z0-9_.-]+"?:' "$file" | tr -d '":'
  exit 0
fi

# Runs on the host: the file arrives on stdin, Puppet's bundled ruby picks the
# one ciphertext, eyaml decrypts it with that host's own key.
# shellcheck disable=SC2016  # deliberately single-quoted: runs on the remote host
remote='
set -euo pipefail
d=/etc/puppetlabs/puppet/eyaml/hosts/"$2"
ct=$(/opt/puppetlabs/puppet/bin/ruby -ryaml -e "v = YAML.safe_load(STDIN.read)[ARGV[0]]; abort(\"key not found: #{ARGV[0]}\") unless v; puts v.to_s.gsub(/\s+/, \"\")" "$1")
/opt/puppetlabs/puppet/bin/eyaml decrypt -s "$ct" \
  --pkcs7-private-key="$d"/private_key.pkcs7.pem \
  --pkcs7-public-key="$d"/public_key.pkcs7.pem
'
ssh "root@${ssh_target}" bash -c "'$remote'" _ "$key" "$cert" < "$file"
