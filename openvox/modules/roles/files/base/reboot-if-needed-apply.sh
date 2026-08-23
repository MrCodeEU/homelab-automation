#!/usr/bin/env bash
# Only included when both reboot_if_needed and reboot_enabled are true -
# default off (see roles::base). rc 0 = no reboot needed, 1 = reboot
# needed, 127 = tool absent. Anything else means "do not know", and not
# knowing must not mean rebooting.
set -euo pipefail
rc=0
needs-restarting -r >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  echo "rebooting to activate installed kernel/library updates (OpenVox)"
  shutdown -r +1 "Rebooting to activate installed kernel/library updates (OpenVox)"
else
  echo "no reboot needed (needs-restarting rc=${rc})"
fi
