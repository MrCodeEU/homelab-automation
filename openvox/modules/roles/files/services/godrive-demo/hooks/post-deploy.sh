#!/usr/bin/env bash
set -euo pipefail

CONTAINER="godrive-demo"
TIMER_NAME="godrive-demo-reset"

cat > /etc/systemd/system/${TIMER_NAME}.service <<'EOF'
[Unit]
Description=Reset goDrive demo data (daily restart)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker restart godrive-demo
EOF

cat > /etc/systemd/system/${TIMER_NAME}.timer <<'EOF'
[Unit]
Description=Daily reset of goDrive demo container

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${TIMER_NAME}.timer

echo "SUCCESS: godrive-demo daily reset timer enabled."
