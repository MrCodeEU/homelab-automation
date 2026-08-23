#!/usr/bin/env bash
# Non-blocking, matches the Ansible role's own failed_when: false -
# certs may not exist yet on a genuinely fresh install.
set -euo pipefail
/usr/local/bin/mailcow-cert-sync.sh || true
