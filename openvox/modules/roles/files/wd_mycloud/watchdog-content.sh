#!/bin/sh
TS_DIR=/mnt/HD/HD_a2/tailscale/current
LOG=/mnt/HD/HD_a2/tailscale/tailscaled.log
if ! pgrep -f "tailscaled --statedir" >/dev/null 2>&1; then
    i=0
    while [ ! -x "$TS_DIR/tailscaled" ] && [ "$i" -lt 12 ]; do
        sleep 5
        i=$((i + 1))
    done
    cd "$TS_DIR"
    nohup ./tailscaled --statedir=/mnt/HD/HD_a2/tailscale/tailscale_lib >> "$LOG" 2>&1 &
    sleep 3
    ./tailscale up --hostname=wd-mycloud --accept-dns=false --ssh >> "$LOG" 2>&1
fi
