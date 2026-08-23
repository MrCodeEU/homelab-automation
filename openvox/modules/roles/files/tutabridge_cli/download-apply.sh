#!/usr/bin/env bash
set -euo pipefail
DST=/opt/tutabridge/tutabridge-cli
EXPECTED=a98c7ed472fc19b4b7bd80ea7ab2abd5a47212409c786f943083622837f8947c
URL=https://github.com/spartanz51/tutabridge/releases/download/v0.1.0-rc.9/tutabridge-linux-x86_64
TMP=$(mktemp)
curl -sSL -o "$TMP" "$URL"
ACTUAL=$(sha256sum "$TMP" | awk '{print $1}')
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ERROR: checksum mismatch for $URL (expected $EXPECTED, got $ACTUAL)" >&2
  rm -f "$TMP"
  exit 1
fi
mv "$TMP" "$DST"
chmod 755 "$DST"
echo "downloaded $DST"
