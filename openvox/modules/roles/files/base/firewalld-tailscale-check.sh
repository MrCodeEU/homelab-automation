#!/usr/bin/env bash
set -euo pipefail
firewall-cmd --zone=trusted --list-sources | grep -qwF '100.64.0.0/10'
