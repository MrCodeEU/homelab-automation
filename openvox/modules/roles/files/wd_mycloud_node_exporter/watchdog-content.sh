#!/bin/sh
NE_DIR=/mnt/HD/HD_a2/node_exporter/current
LOG=/mnt/HD/HD_a2/node_exporter/node_exporter.log
if ! pgrep -f "node_exporter --web.listen-address" >/dev/null 2>&1; then
    i=0
    while [ ! -x "$NE_DIR/node_exporter" ] && [ "$i" -lt 12 ]; do
        sleep 5
        i=$((i + 1))
    done
    i=0
    while ! ip -4 addr show tailscale0 2>/dev/null | grep -q "100.100.10.5" && [ "$i" -lt 12 ]; do
        sleep 5
        i=$((i + 1))
    done
    cd "$NE_DIR" || exit 1
    nohup ./node_exporter --web.listen-address=100.100.10.5:9100 >> "$LOG" 2>&1 &
fi
