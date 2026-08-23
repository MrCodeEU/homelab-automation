#!/usr/bin/env bash
set -euo pipefail
[ -f /opt/mailcow-dockerized/.env ] && cmp -s /opt/mailcow-dockerized/mailcow.conf /opt/mailcow-dockerized/.env
