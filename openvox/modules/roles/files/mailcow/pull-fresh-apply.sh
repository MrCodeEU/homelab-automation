#!/usr/bin/env bash
# refreshonly - only runs when the clone exec actually cloned (subscribed
# via Puppet notify, not a marker file). Avoids an unnecessary pull on
# every ordinary apply against an already-running install.
set -euo pipefail
cd /opt/mailcow-dockerized
docker compose pull
