#!/usr/bin/env bash
# unless-guard for base-reboot-if-needed: exit 0 = no reboot needed (or
# not known - not knowing must not mean rebooting), so the exec is
# skipped and never notifies Reboot['base-reboot-after-run']. Exit 1 =
# reboot genuinely needed, so the exec runs and does notify.
#
# The actual reboot is applied via the reboot module's apply => 'finished'
# (see base.pp), not here - a raw `shutdown -r +1` used to fire mid-catalog,
# partway through this same host's remaining Exec resources, and killed
# them with SIGHUP when the box went down before the run finished
# (first seen live on the 2026-09-13 and 2026-09-20 weekly-maintenance
# runs - both times a still-running exec like the mljr/nuc service deploy
# execs got SIGHUP almost exactly 60s after this check, matching
# `shutdown -r +1`'s delay).
set -uo pipefail
rc=0
needs-restarting -r >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 1 ]
