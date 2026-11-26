#!/usr/bin/env bash
# Fail when a compose file under services/ publishes a port without a host
# address. Docker publishes "8080:80" on 0.0.0.0 and [::] and its own
# iptables rules bypass firewalld, so the port is open to the whole LAN.
# Services bind "${BIND_ADDR:-127.0.0.1}:<port>:<port>" (BIND_ADDR is
# 127.0.0.1 in every rendered .env; the Ziti routers dial 127.0.0.1). A port
# that must be on the LAN says so with an explicit "0.0.0.0:" and a comment.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bad=()
while IFS= read -r f; do
  while IFS= read -r hit; do
    bad+=("$f:$hit")
  done < <(awk '
    # Leave the ports block at the next key at or above its indent.
    in_ports {
      match($0, /^ */); ind = RLENGTH
      if ($0 !~ /^[[:space:]]*(-|#|$)/ && ind <= pind) in_ports = 0
    }
    in_ports && /^[[:space:]]*-[[:space:]]/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      gsub(/["'\'']/, "", item)
      sub(/[[:space:]]*#.*$/, "", item)
      # host address given: ${VAR...}:, IPv4: or [IPv6]:
      if (item ~ /^\$\{/ || item ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/ || item ~ /^\[/) next
      print NR ": " $0
    }
    /^[[:space:]]*ports:[[:space:]]*$/ { in_ports = 1; match($0, /^ */); pind = RLENGTH }
  ' "$f")
done < <(git ls-files -- 'services/*docker-compose.yml')

if [ ${#bad[@]} -gt 0 ]; then
  printf 'FAIL  published port without a host address (Docker binds 0.0.0.0):\n' >&2
  printf '  %s\n' "${bad[@]}" >&2
  printf 'Fix: "${BIND_ADDR:-127.0.0.1}:<host>:<container>", or "0.0.0.0:..." with a comment if the LAN needs it\n' >&2
  exit 1
fi
echo "OK  every published port in services/ names its host address"
