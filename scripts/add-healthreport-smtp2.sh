#!/usr/bin/env bash
# Remote eyaml command embeds a fixed, script-local path, same pattern as
# scripts/rotate-eyaml-secret.sh.
# shellcheck disable=SC2029
# Add the healthreport backup-relay secrets (vault_healthreport_smtp2_*) to
# nuc's eyaml. Prompts for each value (password hidden), encrypts it on nuc
# with nuc's own public key (value piped over stdin, never argv), and
# appends/replaces the key in the local file. Review `git diff`, then PR.
set -euo pipefail

# SSH over Ziti with the opkssh key (scripts/opk-ready.sh).
"$(dirname "${BASH_SOURCE[0]}")/opk-ready.sh"
cd "$(git rev-parse --show-toplevel)"

certname="nuc.int.mljr.eu"              # Puppet identity: secrets file + key dir
ssh_target="nuc.ziti"                  # SSH transport (Ziti)
file="openvox/data/secrets/${certname}.eyaml"
pub="/etc/puppetlabs/puppet/eyaml/hosts/${certname}/public_key.pkcs7.pem"

read -rp "Relay host (e.g. smtp-relay.brevo.com): " host
read -rp "Port [587]: " port; port="${port:-587}"
read -rp "Username: " user
read -rsp "Password / API key: " pass; echo
read -rp "From address (must be verified at the provider): " from

put() {
  local key="$1" val="$2" cipher
  cipher="$(printf '%s' "$val" | ssh "root@${ssh_target}" \
    "/opt/puppetlabs/puppet/bin/eyaml encrypt --pkcs7-public-key='${pub}' -o string --stdin")"
  cipher="${cipher%$'\n'}"
  [[ "$cipher" =~ ^ENC\[PKCS7, ]] || { echo "bad eyaml output for $key" >&2; exit 1; }
  sed -i "/^\"${key}\":/d" "$file"
  [ -n "$(tail -c1 "$file")" ] && echo >> "$file"
  printf '"%s": "%s"\n' "$key" "$cipher" >> "$file"
  echo "ok: $key"
}

put vault_healthreport_smtp2_host "$host"
put vault_healthreport_smtp2_port "$port"
put vault_healthreport_smtp2_user "$user"
put vault_healthreport_smtp2_password "$pass"
put vault_healthreport_smtp2_from "$from"
echo "Done. git diff --stat $file, then commit + PR."
