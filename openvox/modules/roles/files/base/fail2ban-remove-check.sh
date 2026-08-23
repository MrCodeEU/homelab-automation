#!/usr/bin/env bash
set -euo pipefail
[ -z "$(rpm -qa 'fail2ban*')" ] && [ ! -d /etc/fail2ban ]
