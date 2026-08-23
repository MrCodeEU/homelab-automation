#!/usr/bin/env bash
# Runs ON nas via ssh (pushed as a real file, not an inline quoted
# one-liner - see roles::wd_mycloud_proxy's own header comment for why
# nested shell-quoting layers are worth avoiding here).
set -uo pipefail
DEST="/mnt/user/appdata/homelab/bin/homelab-facts"
CANDIDATE="/tmp/openvox-homelab-facts-candidate.py"

if cmp -s "$CANDIDATE" "$DEST" 2>/dev/null \
  && [ -L /usr/local/bin/homelab-facts ] \
  && [ "$(readlink /usr/local/bin/homelab-facts)" = "$DEST" ]; then
  RC=0
else
  RC=1
fi
rm -f "$CANDIDATE"
exit "$RC"
