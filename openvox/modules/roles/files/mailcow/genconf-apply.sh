#!/usr/bin/env bash
# Only ever runs once - mailcow.conf holds generated DBPASS/DBROOT/
# REDISPASS secrets that must never be regenerated on an existing
# install (would orphan the real database/redis credentials).
set -euo pipefail
cd /opt/mailcow-dockerized
echo -e "${MAILCOW_HOSTNAME}\n${MAILCOW_TIMEZONE}" | ./generate_config.sh
