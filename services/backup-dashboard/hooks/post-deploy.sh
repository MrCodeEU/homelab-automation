#!/usr/bin/env bash
# Build the collector image, start the always-on web container, and install
# the systemd timer that drives the collector.
#
# Mirrors services/healthreport/hooks/post-deploy.sh closely, with one
# difference: healthreport is a single-service project that uses a
# --noop default command to dodge "no service selected" on `up -d`.
# This project has two services - web (unprofiled, starts normally) and
# collector (profiled "cron", intentionally skipped by `up -d`) - so no
# workaround is needed, `docker compose up -d` here just starts `web`.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="homelab-backup-dashboard"
SCHEDULE="${BACKUP_DASHBOARD_REFRESH_INTERVAL:-*:0/15}"

cd "$SERVICE_DIR"

echo "==> building backup dashboard collector image"
docker compose build collector

# No Puppet class owns this path - created here so a manual `docker
# compose run` works even without a prior apply. uid 10001 matches the
# unprivileged user in the Dockerfile - the same uid healthreport's
# container runs as, not a separate one, since this container reads
# healthreport's own SSH key read-only.
install -d -o 10001 -g 10001 -m 0755 /var/lib/backup-dashboard/state

cat > /etc/systemd/system/${UNIT_NAME}.service <<EOF
[Unit]
Description=Backup dashboard state collector
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SERVICE_DIR}
ExecStart=/usr/bin/docker compose --profile cron run --rm collector
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/${UNIT_NAME}.timer <<EOF
[Unit]
Description=Refresh the backup dashboard on a schedule

[Timer]
OnCalendar=${SCHEDULE}
RandomizedDelaySec=1min
# Catch up after the host was down at the scheduled time.
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${UNIT_NAME}.timer

echo "==> ${UNIT_NAME}.timer active; next run:"
systemctl list-timers ${UNIT_NAME}.timer --no-pager || true

# The web container serves whatever the last collector run wrote. Run one
# pass now so the page is not empty on the first deploy - `up -d` alone only
# starts `web`.
echo "==> running initial collector pass"
docker compose --profile cron run --rm collector || echo "WARNING: initial collector run failed - web will serve an empty page until the timer's next run or a manual retry"
