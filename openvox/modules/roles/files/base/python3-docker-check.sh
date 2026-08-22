#!/usr/bin/env bash
set -euo pipefail
rpm -q python3-docker >/dev/null 2>&1 || python3 -c 'import docker' >/dev/null 2>&1
