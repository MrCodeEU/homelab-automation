#!/usr/bin/env bash
# Wait for both Syncthing instances to be reachable, then run the
# provisioning script. NAS_SYNCTHING_URL / NAS_SYNCTHING_API_KEY come from
# this service's .env (see env.j2), exported into the environment by the
# services role before this hook runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_for() {
    local url="$1" label="$2"
    for _ in $(seq 1 30); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "FAILED: $label did not become ready at $url" >&2
    return 1
}

wait_for "http://127.0.0.1:8384/rest/noauth/health" "local Syncthing"
wait_for "${NAS_SYNCTHING_URL}/rest/noauth/health" "NAS Syncthing"

# GODEBUG= clears this host's system-wide GODEBUG=tlskyber=0 (set in
# /etc/profile.d/go.sh, leftover from an old Go install) - Go 1.24+
# removed that debug flag entirely, so any Go 1.24+ binary run with it
# still set exits with a fatal "removed GODEBUG" panic before main()
# even runs. Scoped to just this process, not touching the system file.
GODEBUG= "${SCRIPT_DIR}/provision-syncthing"
