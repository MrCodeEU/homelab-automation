#!/usr/bin/env bash
# Print one decrypted value from a host's eyaml file. Decrypts on the host with
# its own key; plaintext goes to stdout only, nothing is written to disk on
# either side. Never pipe the output into a log or a commit.
# usage: eyaml-get.sh <mljr|nuc|ugreen> [key]   (no key = list key names)
set -euo pipefail

host="${1:-}"
key="${2:-}"
case "$host" in
  mljr|nuc|ugreen) ;;
  *) echo "usage: $0 <mljr|nuc|ugreen> [key]" >&2; exit 2 ;;
esac

cert="${host}.tail33930.ts.net"
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
ssh "root@${cert}" bash -c "'$remote'" _ "$key" "$cert" < "$file"
