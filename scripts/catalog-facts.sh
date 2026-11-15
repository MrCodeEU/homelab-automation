#!/usr/bin/env bash
# Refresh the facts the catalog diff compiles with (openvox/ci/facts/), from
# the hosts themselves:
#
#   catalog-facts.sh [mljr|nuc|ugreen ...]     (default: all three)
#
# The repository is public, so only an allowlist is kept: OS, architecture,
# path, hostname/FQDN/domain, and the custom facts openvox-apply.sh sets
# (with their default values). Kernel versions are replaced by 0.0.0: no
# manifest here uses them, and they would publish each host's patch level.
# No IPs, MACs, disks, serials or SSH keys.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${repo}/openvox/ci/facts"
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

hosts=("$@")
[ "${#hosts[@]}" -gt 0 ] || hosts=(mljr nuc ugreen)
for h in "${hosts[@]}"; do
  case "$h" in
    mljr|nuc|ugreen) ;;
    *) echo "unknown host: $h" >&2; exit 2 ;;
  esac
  cert="${h}.int.mljr.eu"
  # GODEBUG= for UGOS (its global GODEBUG=tlskyber=0 aborts Go programs).
  ssh "root@${h}.tail33930.ts.net" \
    'GODEBUG= /opt/puppetlabs/bin/facter -j os kernel architecture hardwaremodel path networking 2>/dev/null' |
    jq --arg c "$cert" '{
      name: $c,
      values: {
        os: .os, kernel: .kernel, architecture: .architecture,
        hardwaremodel: .hardwaremodel, path: .path,
        kernelrelease: "0.0.0", kernelversion: "0.0.0", kernelmajversion: "0.0",
        networking: {hostname: .networking.hostname, fqdn: .networking.fqdn, domain: .networking.domain},
        clientcert: $c,
        openvox_weekly_maintenance: "false",
        openvox_staging_services: "",
        openvox_recovery_services: ""
      }
    }' > "${out_dir}/${cert}.json.tmp"
  mv "${out_dir}/${cert}.json.tmp" "${out_dir}/${cert}.json"
  echo "${out_dir}/${cert}.json"
done
