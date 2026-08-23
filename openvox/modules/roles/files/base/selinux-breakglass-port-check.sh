#!/usr/bin/env bash
set -euo pipefail
semanage port -l | grep -w ssh_port_t | grep -qw "${BREAKGLASS_PORT}"
