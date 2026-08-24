#!/usr/bin/env bash
# Runs Uptime Kuma auto-provisioning - ported from
# ansible/roles/services/tasks/main.yml's Kuma Provisioning block.
# KUMA_USERNAME/KUMA_PASSWORD arrive via the calling exec's environment.
#
# Non-blocking throughout (matches Ansible's failed_when: false): Kuma
# being unreachable, or the provisioning script itself failing, prints a
# warning and exits 0 rather than failing the whole catalog run. The
# checksum file is only updated on a real success, so a failed run is
# retried on the next apply instead of being silently marked done.
#
# Args: $1 = kuma_dir (e.g. /opt/kuma), $2 = new checksum to store on success.
set -uo pipefail
kuma_dir="$1"
new_hash="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ready=false
for _ in $(seq 1 12); do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3001 2>/dev/null || echo "000")
  case "$code" in
    200|302) ready=true; break ;;
  esac
  sleep 5
done

if [ "$ready" != "true" ]; then
  echo "WARNING: Kuma not reachable on localhost:3001 - skipping provisioning (non-blocking, will retry next run)" >&2
  exit 0
fi

export KUMA_URL="http://localhost:3001"

if "${script_dir}/provision-kuma" "${kuma_dir}/services.yml"; then
  printf '%s' "$new_hash" > "${kuma_dir}/.services-checksum"
  echo "Kuma provisioning succeeded"
else
  echo "WARNING: Kuma provisioning failed (non-blocking) - checksum NOT updated, will retry next run" >&2
fi
exit 0
