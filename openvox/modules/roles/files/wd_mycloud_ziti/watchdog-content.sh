#!/bin/sh
# Starts ziti-edge-tunnel in run-host mode (hosts services, intercepts
# nothing: no tun device) once the identity is enrolled
# (scripts/ziti-enroll-wd-mycloud.sh). Run from cron and the clamAV boot
# hook; the tunneler itself retries the controller until the network is up.
BASE=/mnt/HD/HD_a2/ziti
ID="$BASE/identity/wd-mycloud.json"
LOG="$BASE/ziti-edge-tunnel.log"
[ -f "$ID" ] || exit 0
# [z]: the pattern must not match a command line that merely contains it
# (a remote shell running this script).
if ! pgrep -f "[z]iti-edge-tunnel run-host" >/dev/null 2>&1; then
    i=0
    while [ ! -x "$BASE/current/ziti-edge-tunnel" ] && [ "$i" -lt 12 ]; do
        sleep 5
        i=$((i + 1))
    done
    # Keep one old log; the data partition has no logrotate.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 5242880 ]; then
        mv -f "$LOG" "$LOG.1"
    fi
    cd "$BASE/current" || exit 1
    nohup ./ziti-edge-tunnel run-host --identity "$ID" --verbose 2 >> "$LOG" 2>&1 &
fi
