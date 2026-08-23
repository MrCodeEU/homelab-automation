#!/usr/bin/env bash
set -uo pipefail
DST=/opt/tutabridge/tutabridge-cli
EXPECTED=a98c7ed472fc19b4b7bd80ea7ab2abd5a47212409c786f943083622837f8947c
[ -f "$DST" ] && [ "$(sha256sum "$DST" | awk '{print $1}')" = "$EXPECTED" ]
