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
