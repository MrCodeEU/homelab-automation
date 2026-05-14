#!/usr/bin/env bash
set -euo pipefail

SERVICE_PATH="${2:-${SERVICE_PATH:-/opt/signoz}}"

python3 "$SERVICE_PATH/hooks/provision-dashboard.py"
