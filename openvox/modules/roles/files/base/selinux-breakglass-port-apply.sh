#!/usr/bin/env bash
set -euo pipefail
semanage port -a -t ssh_port_t -p tcp "${BREAKGLASS_PORT}"
