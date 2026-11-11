#!/bin/bash
# reset.sh: remove everything the slice creates, so the next tool starts
# from the same clean host (Docker, git, rsync, Ziti and OpenVox stay).
set -u
systemctl disable -q --now spike-pull.timer 2>/dev/null
systemctl disable -q --now spike-iperf3 2>/dev/null
rm -f /etc/systemd/system/spike-iperf3.service /etc/systemd/system/spike-pull.*
systemctl daemon-reload
docker compose -f /opt/whoami/docker-compose.yml down -v 2>/dev/null
rm -rf /opt/whoami /etc/spike /var/lib/spike-pull /usr/local/sbin/spike-* /etc/ssh/sshd_config.d/50-spike.conf
userdel -r spikefacts 2>/dev/null
dnf -y -q remove iperf3 >/dev/null 2>&1
systemctl reload sshd
echo "$(hostname -s) reset"
