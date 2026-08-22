#!/usr/bin/env bash
set -euo pipefail
[ "$(timedatectl show -p Timezone --value)" = "${TZ_VALUE}" ]
