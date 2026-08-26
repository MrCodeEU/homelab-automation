# Netronome

`speedtest.mljr.eu` runs Netronome on `nuc` and is proxied by Caddy on `mljr`.

## Why `nuc`

Netronome is placed on `nuc` because it is the stronger compute node and less critical than the public ingress VPS. The public hostname still stays under `mljr.eu`, but the workload runs on `nuc`.

For `mljr` outbound checks, configure `mljr` as a target or test endpoint inside Netronome rather than hosting the UI on the ingress node.

## Runtime

- Image: `ghcr.io/autobrr/netronome:latest`
- Container port: `7575`
- Host port: `8090`
- Persistent volume: `netronome-data:/data`
- Listen address: `NETRONOME__HOST=0.0.0.0`
- Session secret: `NETRONOME__SESSION_SECRET`
- Capabilities: `NET_RAW` and `NET_ADMIN` for network diagnostics

The staging Compose file uses host port `18090` and `netronome-staging-data`.

## Configuration

Netronome users, iperf targets, Speedtest.net schedules, packet-loss checks, and alerts are configured in the Netronome UI.

The post-deploy hook uses the Netronome CLI to create or update the `admin` user password from `NETRONOME_ADMIN_PASSWORD`.

Required/optional secrets:

| Secret | Purpose |
|--------|---------|
| `NETRONOME_ADMIN_PASSWORD` | Required admin user password |
| `NETRONOME_SESSION_SECRET` | Optional stable session signing secret |

## Mesh monitoring (agents + iperf3)

Beyond the single scheduled external Ookla test, the server auto-discovers
per-host **agents** (CPU/mem/disk/bandwidth/temp) over Tailscale, and can
run mesh **iperf3** tests between hosts - two separate Netronome features,
set up differently.

### Tailscale auto-discovery (server side)

The `speedtest` container runs with `network_mode: host` and mounts the
host's own already-authenticated `tailscaled` socket
(`/var/run/tailscale:/var/run/tailscale:ro`, `NETRONOME__TAILSCALE_METHOD:
host`) - no separate tsnet identity or auth key needed. With
`NETRONOME__TAILSCALE_AUTO_DISCOVER: "true"`, it polls the tailnet every
`NETRONOME__TAILSCALE_DISCOVERY_INTERVAL` (5m) and probes each peer's
short MagicDNS hostname on `NETRONOME__TAILSCALE_DISCOVERY_PORT` (8200)
for `/netronome/info`. This depends on MagicDNS short-hostname resolution
working *inside the server's own container* - if a host stops showing up,
check `docker exec speedtest cat /etc/resolv.conf` there first (should be
`100.100.100.100`, not the LAN router).

### Agents (`roles::netronome_agent`)

Deployed on `mljr`, `nuc`, `ugreen` (Puppet role) and `nas` (static compose
via `services_catalog`, `nuc` proxy-execs it). Each host runs two
containers in `network_mode: host`:

- `netronome-agent` (`ghcr.io/autobrr/netronome:latest`, `agent
  --tailscale --tailscale-method host`) - the metrics endpoint the server
  discovers.
- `netronome-vnstat` (`ghcr.io/vergoh/vnstat:latest`) - a real `vnstatd`
  daemon with a persisted `/var/lib/vnstat` volume, shared read-only with
  the agent. Required for historical bandwidth export: the agent's own
  bundled `vnstat` binary is CLI-only and never starts the daemon itself,
  so without this sidecar `/export/historical` 500s forever even though
  live bandwidth (which doesn't need the db) works fine.

Both containers pin the same interface explicitly (`mljr`=`eth0`,
`nuc`=`enp2s0`, `ugreen`=`eth0`, `nas`=`br0`) so they agree on which
interface's data actually gets queried - on multi-interface hosts (`nas`
has ~35: docker bridges, bond0, unused NICs, a tunnel) vnstat's own
auto-pick can land on an inert one.

Auto-discovered Tailscale agents get created by the server with a blank
API key by design - the "Edit Monitoring Settings" dialog for a
Tailscale-connected agent has no field to set one at all. Tailnet
membership is the trust boundary in this mode; don't set
`NETRONOME__AGENT_API_KEY` on these, it just makes the agent 401 forever.

`wd-mycloud` does not get an agent: it has no `vnstat` (BusyBox, no
package manager), so bandwidth data - the main reason to run an agent -
wouldn't work there anyway. Only CPU/mem/disk would populate. Decided not
worth the added complexity on this already-fragile device (2026-08-26).

### Mesh iperf3 tests + low-speed alerts (auto-provisioned)

`roles::iperf3` runs an `iperf3 -s` server (host network) on `mljr`,
`nuc`, `ugreen`; `nas` gets one via `services_catalog` (`iperf3-nas`,
`nuc` proxy-execs it). `wd-mycloud` has none.

**Architecturally this is nuc -> {mljr, ugreen, nas}, not a true
all-pairs mesh**: Netronome runs as a single instance (this container, on
`nuc`) and is the only process that ever execs `iperf3` as a client - the
per-host agents only report their own metrics, they never run their own
scheduled tests. A real all-pairs mesh would need a separate Netronome
instance per host, which is out of scope.

Despite the UI's "Edit Monitoring Settings" dialog making this look
manual-only, Netronome does have a real session-cookie-authenticated REST
API for it (`POST /api/iperf/servers`, `/api/schedules`,
`/api/notifications/{channels,rules}` - confirmed by reading
`internal/server/`, `internal/handlers/iperf.go`,
`internal/database/notifications_types.go` in the upstream repo). The
`speedtest` service's own `hooks/post-deploy.sh` uses it, idempotently, on
every deploy:

- Registers `mljr`/`ugreen`/`nas` (port `5201`) as saved iperf3 targets
  (populates the UI's server dropdown only - schedules don't reference
  these by ID, see below).
- Creates one hourly (`1h`) schedule **per target host**, download+upload
  - NOT one combined schedule. Confirmed live (2026-08-26):
  `RunTest`'s iperf3 branch (`internal/speedtest/speedtest.go`) dispatches
  on a single `Options.ServerHost` string, not `Options.ServerIDs` -
  `serverIds` is only consumed by the Speedtest.net/Ookla path. A
  combined schedule with `serverIds:["1","2","3"]` and no `serverHost`
  silently falls through to that Ookla path and fails forever
  (`"requested server(s) [1 2 3] not found in public list"`, retried every
  scheduler tick since a failed run never advances `nextRun`) - the saved
  `/iperf/servers` IDs above are not a valid way to target a schedule.
- Creates an ntfy channel (`ntfy://ntfy.mljr.eu/speed`, same
  unauthenticated instance as the `backup`/`homelab-health` topics) and
  low-speed rules for both `download_low`/`upload_low` at 20 Mbps
  (`threshold_operator: lt`).

To change the threshold, targets, or interval, either edit
`hooks/post-deploy.sh` (idempotency checks match on server name / schedule
useIperf+serverHost / channel URL / rule channel+event - change the
matched value if you change what gets created, or the old one won't get
cleaned up automatically) or just edit it by hand in the Netronome UI -
the API only creates on first deploy, it doesn't fight manual UI changes
after that (no ongoing reconciliation, same as the admin-password step
above it).
