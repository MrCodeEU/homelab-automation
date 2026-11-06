#!/usr/bin/env bash
# C6 data path test (docs/ZERO_TRUST_PLAN.md Phase 3): iperf3 once over the
# existing path and once over Ziti, alternating, plus the circuit path while
# the Ziti run is going.
#
#   external  mljr -> nas. Baseline: Tailscale. The Nextcloud upload path:
#             nas hosts its own endpoint, so the circuit must be mljr's
#             router only (no hop through nuc, i.e. no FRITZ!Box mesh).
#             Pass: Ziti >= 90 % of Tailscale.
#   lan       nas -> ugreen. Baseline: direct LAN (crosses the mesh once).
#             The circuit must not go through mljr. Pass: Ziti >= 75 %.
#
# Everything is temporary and removed at the end, also on failure:
#   - controller: service c6-iperf (host.v1 127.0.0.1:5299), identities
#     c6-server (Bind) and c6-client (Dial), two service policies
#   - server host: iperf3 -s on 127.0.0.1:5299, container c6-host
#     (`ziti tunnel host`), /tmp/c6
#   - client host: container c6-proxy (`ziti tunnel proxy`, 127.0.0.1:15299),
#     /tmp/c6
# Both identities get the default router policy (#all): this tests the path
# Ziti picks on its own. mljr has no iperf3 package; the client runs it from
# an alpine container there.
#
# Usage: scripts/ziti-c6-iperf.sh <external|lan> [runs] [seconds]
#        (default 3 x 15 s)
#   IPERF_ARGS  extra iperf3 client flags for both runs, e.g. "-R" (server
#               sends) or "-P 4"
#   SERVER_TUNNELER  go (default, `ziti tunnel host`), c
#               (`ziti-edge-tunnel run-host`, the C SDK, no tun device) or
#               router (a temporary edge router c6-router in tunnel host
#               mode, link to mljr, edge listener on 127.0.0.1 only)
# Remote commands are built locally on purpose (constants), hence SC2029.
# shellcheck disable=SC2029
set -euo pipefail

CTRL_HOST=root@mljr.tail33930.ts.net
IMAGE=docker.io/openziti/ziti-cli:2.0.8@sha256:82d76e9b4c15742ac4370529caddd125d30f300ce6a05a500064aa0a80122fdf
ALPINE=docker.io/library/alpine:3.24@sha256:3f4d6b32e26703c6082839234f43769d5046b3ac7c910033911d1e71d8cd630a

MODE="${1:-}"
RUNS="${2:-3}"
SECS="${3:-15}"
IPERF_ARGS="${IPERF_ARGS:-}"
SERVER_TUNNELER="${SERVER_TUNNELER:-go}"
ROUTER_IMAGE=docker.io/openziti/ziti-router:2.0.8@sha256:540e5450f2ecd72cdc0db94bb7d969814f826e19d3bd4bbde192483c38bb5423
EDGE_TUNNEL=docker.io/openziti/ziti-edge-tunnel@sha256:2a103bdd5d242bccd7627e7b860bd37d0c49758b3f2dcda4cc7003c027910c38

case "$MODE" in
  external)
    CLIENT=root@mljr.tail33930.ts.net; SERVER=root@nas.tail33930.ts.net
    SERVER_DIRECT=100.100.10.2 # nas over Tailscale
    FORBIDDEN=nuc.int.mljr.eu; PASS_PCT=90
    IPERF_BIN="docker run --rm --network host $ALPINE sh -c 'apk add -q iperf3 >/dev/null && iperf3 \"\$@\"' iperf3" ;;
  lan)
    CLIENT=root@nas.tail33930.ts.net; SERVER=root@ugreen.tail33930.ts.net
    SERVER_DIRECT=192.168.50.86 # ugreen on the LAN
    FORBIDDEN=mljr.int.mljr.eu; PASS_PCT=75
    IPERF_BIN=iperf3 ;;
  *) echo "usage: $0 <external|lan> [runs] [seconds]" >&2; exit 1 ;;
esac

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

zcli() {
  ssh "$CTRL_HOST" "set -a; . /opt/ziti-controller/.env; set +a
    docker exec ziti-controller ziti edge login localhost:8440 -u admin -p \"\$ZITI_ADMIN_PASSWORD\" -y >/dev/null
    docker exec ziti-controller ziti $*"
}

out=$(mktemp)
cleanup() {
  say "Cleaning up"
  rm -f "$out"
  ssh "$CLIENT" 'docker rm -f c6-proxy >/dev/null 2>&1; rm -rf /tmp/c6' || true
  ssh "$SERVER" 'docker rm -f c6-host >/dev/null 2>&1; pkill -f "iperf3 -s -B 127.0.0.1 -p 5299"; rm -rf /tmp/c6' || true
  for obj in "service-policy c6-dial" "service-policy c6-bind" "identity c6-client" \
             "identity c6-server" "edge-router c6-router" "service c6-iperf" "config c6-iperf-host"; do
    zcli "edge delete $obj" >/dev/null 2>&1 || true
  done
  ssh "$CTRL_HOST" 'docker exec ziti-controller rm -f /tmp/c6-client.jwt /tmp/c6-server.jwt /tmp/c6-router.jwt' || true
}
trap cleanup EXIT

say "Mode $MODE: ${CLIENT#root@} -> ${SERVER#root@}"
say "Creating the temporary service and identities"
cleanup >/dev/null 2>&1
zcli "edge create config c6-iperf-host host.v1 '{\"protocol\":\"tcp\",\"address\":\"127.0.0.1\",\"port\":5299}'" >/dev/null
zcli "edge create service c6-iperf -c c6-iperf-host" >/dev/null
if [ "$SERVER_TUNNELER" = router ]; then
  zcli "edge create edge-router c6-router --tunneler-enabled -o /tmp/c6-router.jwt" >/dev/null
  BINDER=@c6-router
else
  zcli "edge create identity c6-server -o /tmp/c6-server.jwt" >/dev/null
  BINDER=@c6-server
fi
zcli "edge create identity c6-client -o /tmp/c6-client.jwt" >/dev/null
zcli "edge create service-policy c6-bind Bind --identity-roles $BINDER --service-roles @c6-iperf" >/dev/null
zcli "edge create service-policy c6-dial Dial --identity-roles @c6-client --service-roles @c6-iperf" >/dev/null

# Enrol on the host itself; the token goes mljr -> this shell -> host.
enrol() { # host name
  ssh "$CTRL_HOST" "docker exec ziti-controller cat /tmp/$2.jwt" \
    | ssh "$1" "set -e; mkdir -p /tmp/c6; chmod 777 /tmp/c6; cat > /tmp/c6/$2.jwt
        docker run --rm -v /tmp/c6:/z $IMAGE edge enroll -j /z/$2.jwt -o /z/$2.json >/dev/null 2>&1
        rm -f /tmp/c6/$2.jwt; test -s /tmp/c6/$2.json"
}

say "${SERVER#root@}: iperf3 server on 127.0.0.1:5299 behind the $SERVER_TUNNELER tunneler"
if [ "$SERVER_TUNNELER" = router ]; then
  # Same shape as services/ziti-router-nuc/config.yml, minus the LAN edge
  # listener: this router only hosts, so clients never pick it.
  ssh "$CTRL_HOST" "docker exec ziti-controller cat /tmp/c6-router.jwt" \
    | ssh "$SERVER" "set -e; mkdir -p /tmp/c6; chmod 777 /tmp/c6; cat > /tmp/c6/enroll.jwt; chmod 644 /tmp/c6/enroll.jwt
        cat > /tmp/c6/config.yml <<'YML'
v: 3
identity:
  cert:        /ziti-router/c6.cert
  server_cert: /ziti-router/c6.server.chain.cert
  key:         /ziti-router/c6.key
  ca:          /ziti-router/c6.cas
ctrl:
  endpoint: tls:ctrl.ziti.mljr.eu:8441
link:
  dialers:
    - binding: transport
listeners:
  - binding: edge
    address: tls:127.0.0.1:18442
    options:
      advertise: 127.0.0.1:18442
  - binding: tunnel
    options:
      mode: host
edge:
  csr:
    organization: homelab
    sans:
      ip:
        - \"127.0.0.1\"
YML
        chmod 644 /tmp/c6/config.yml"
  host_cmd="-v /tmp/c6:/ziti-router -e ZITI_BOOTSTRAP_CONFIG=false -e ZITI_ROUTER_NAME=c6 -e ZITI_ENROLL_TOKEN=/ziti-router/enroll.jwt $ROUTER_IMAGE run config.yml"
elif [ "$SERVER_TUNNELER" = c ]; then
  enrol "$SERVER" c6-server || die "enrolment on ${SERVER#root@} failed"
  host_cmd="-v /tmp/c6:/ziti-edge-tunnel -e ZITI_IDENTITY_BASENAME=c6-server $EDGE_TUNNEL run-host"
else
  enrol "$SERVER" c6-server || die "enrolment on ${SERVER#root@} failed"
  host_cmd="-v /tmp/c6:/z $IMAGE tunnel host -i /z/c6-server.json"
fi
ssh "$SERVER" "iperf3 -s -B 127.0.0.1 -p 5299 -D
  docker run -d --name c6-host --network host $host_cmd >/dev/null"

say "${CLIENT#root@}: ziti tunnel proxy on 127.0.0.1:15299"
enrol "$CLIENT" c6-client || die "enrolment on ${CLIENT#root@} failed"
ssh "$CLIENT" "docker run -d --name c6-proxy --network host -v /tmp/c6:/z $IMAGE tunnel proxy c6-iperf:15299 -i /z/c6-client.json >/dev/null"

say "Waiting for the terminators"
for _ in $(seq 1 30); do
  want=2; [ "$SERVER_TUNNELER" = router ] && want=1
  [ "$(zcli "edge list terminators 'service.name=\"c6-iperf\"' -j" | grep -c '"routerId"')" -ge "$want" ] && break
  sleep 2
done
zcli "edge list terminators 'service.name=\"c6-iperf\"' -j" | jq -r '.data[] | "    terminator on router \(.router.name)"'
sleep 5

mbit() { jq -r ".end.sum_received.bits_per_second/1e6|floor" "$1"; }

direct=(); ziti=(); hairpin=false
for i in $(seq 1 "$RUNS"); do
  say "Run $i/$RUNS"
  ssh "$SERVER" "timeout $((SECS + 60)) iperf3 -s -1 -B $SERVER_DIRECT -p 5298 >/dev/null 2>&1 &"
  sleep 1
  ssh "$CLIENT" "$IPERF_BIN -c $SERVER_DIRECT -p 5298 -t $SECS $IPERF_ARGS -J" > "$out"
  d=$(mbit "$out"); direct+=("$d")
  echo "    baseline: $d Mbit/s"
  ssh "$CLIENT" "$IPERF_BIN -c 127.0.0.1 -p 15299 -t $SECS $IPERF_ARGS -J" > "$out" &
  pid=$!
  sleep $((SECS / 2))
  path=$(zcli "fabric list circuits -j" | jq -r '[.data[] | select(.service.name=="c6-iperf") | [.path.nodes[].name] | join(" -> ")] | unique | join(", ")')
  wait "$pid"
  z=$(mbit "$out"); ziti+=("$z")
  echo "    ziti:     $z Mbit/s   circuit path: ${path:-none seen}"
  case "$path" in *"$FORBIDDEN"*) hairpin=true; echo "    FAIL: circuit goes through $FORBIDDEN" ;; esac
done

sum() { local s=0 v; for v in "$@"; do s=$((s + v)); done; echo "$s"; }
pct=$(( $(sum "${ziti[@]}") * 100 / ( $(sum "${direct[@]}") > 0 ? $(sum "${direct[@]}") : 1 ) ))
say "Result ($MODE)"
echo "    baseline Mbit/s: ${direct[*]}"
echo "    ziti     Mbit/s: ${ziti[*]}"
echo "    ziti/baseline:   $pct % (pass >= $PASS_PCT %), hop through $FORBIDDEN: $hairpin"
if [ "$pct" -ge "$PASS_PCT" ] && ! $hairpin; then echo "    PASS"; else echo "    FAIL"; fi
