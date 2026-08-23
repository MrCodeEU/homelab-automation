#!/usr/bin/env bash
set -euo pipefail
DOCKER_ROOT="${ALLOY_DOCKER_ROOT:-/var/lib/docker}"
CONFIG=/opt/grafana-alloy/config.alloy
MARKER=/opt/grafana-alloy/.config-hash

docker pull grafana/alloy:latest
docker rm -f grafana-alloy >/dev/null 2>&1 || true
docker run -d \
  --name grafana-alloy \
  --restart unless-stopped \
  --network host \
  --pid host \
  --user root \
  --device-cgroup-rule "b 8:* r" \
  --device-cgroup-rule "b 259:* r" \
  -v "$CONFIG:/etc/alloy/config.alloy:ro" \
  -v /opt/grafana-alloy/data:/var/lib/alloy/data \
  -v /:/hostfs:ro \
  -v /proc:/hostfs/proc:ro \
  -v /sys:/hostfs/sys:ro \
  -v /sys:/sys:ro \
  -v "$DOCKER_ROOT:$DOCKER_ROOT:ro" \
  -v /dev/disk:/dev/disk:ro \
  -v /dev:/dev:ro \
  -v /run/systemd/private:/run/systemd/private:ro \
  -v /var/log:/var/log:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /run/containerd/containerd.sock:/run/containerd/containerd.sock:ro \
  --label homelab.managed=true \
  --label homelab.component=standalone-container \
  --label homelab.name=grafana-alloy \
  grafana/alloy:latest \
  run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data /etc/alloy/config.alloy

sha256sum "$CONFIG" | awk '{print $1}' > "$MARKER"
echo "grafana-alloy container (re)created"
