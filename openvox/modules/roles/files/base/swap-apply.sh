#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "${SWAP_PATH}" ]; then
  fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_PATH}"
  chmod 600 "${SWAP_PATH}"
  mkswap "${SWAP_PATH}"
fi

grep -qxF "${SWAP_PATH} none swap sw 0 0" /etc/fstab || \
  echo "${SWAP_PATH} none swap sw 0 0" >> /etc/fstab

# "Device or resource busy" means it's already active - not a real
# failure, matches the Ansible role's own failed_when guard for the same
# swapon call.
set +e
out=$(swapon "${SWAP_PATH}" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q 'Device or resource busy' <<<"$out"; then
  echo "$out" >&2
  exit "$rc"
fi
