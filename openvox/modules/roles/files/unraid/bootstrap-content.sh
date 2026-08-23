#!/bin/bash
# Homelab Unraid bootstrap
# Managed by OpenVox (roles::unraid_proxy, proxy-exec from nuc) - do not edit manually
#
# Runs at array start. Unraid rebuilds / from /boot/config on every boot, so
# everything below re-creates the tmpfs-side state written earlier.
#
# Safe to run repeatedly: every step is idempotent.

#arrayStarted=true
#name=homelab-compose-up

set -uo pipefail

BASE="/mnt/user/appdata/homelab"
LOG="/var/log/homelab-bootstrap.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

if [ ! -d "$BASE" ]; then
    log "ERROR: $BASE does not exist - array not mounted? Aborting."
    exit 1
fi

# 1. Re-link helper binaries into PATH (/usr/local/bin is tmpfs).
if [ -d "$BASE/bin" ]; then
    for src in "$BASE"/bin/*; do
        [ -f "$src" ] || continue
        ln -sf "$src" "/usr/local/bin/$(basename "$src")"
        log "linked $(basename "$src") into /usr/local/bin"
    done
fi

# 2. Restore registry credentials (/root is tmpfs, the array copy is canonical).
if [ -d "$BASE/.docker" ]; then
    if [ -e /root/.docker ] && [ ! -L /root/.docker ]; then
        mv /root/.docker "/root/.docker.pre-openvox.$(date +%s)"
        log "moved pre-existing /root/.docker aside"
    fi
    ln -sfn "$BASE/.docker" /root/.docker
    log "linked registry credentials from $BASE/.docker"
fi

# 3. Bring up every managed compose project.
for dir in "$BASE"/*/; do
    [ -f "${dir}docker-compose.yml" ] || continue
    name="$(basename "$dir")"
    log "starting compose project: $name"
    if ! (cd "$dir" && docker compose up -d 2>&1 | tee -a "$LOG"); then
        log "ERROR: compose up failed for $name"
    fi
done

log "bootstrap complete"
