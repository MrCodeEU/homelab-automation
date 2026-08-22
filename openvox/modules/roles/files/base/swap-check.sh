#!/usr/bin/env bash
# `swapon --show --output NAME` does not reliably filter to just the NAME
# column on this util-linux version (2.37.4) - confirmed live, --output
# silently fails to filter and the full multi-column row comes back
# instead, meaning it would never exact-match a bare path. The Ansible
# role's own equivalent task had this exact same defect and relied on
# swapon's "Device or resource busy" error being treated as
# already-active rather than a real check (see swap-apply.sh) - checking
# the fstab line plus file presence here instead, which is reliable.
set -euo pipefail
[ -f "${SWAP_PATH}" ] && grep -qxF "${SWAP_PATH} none swap sw 0 0" /etc/fstab
