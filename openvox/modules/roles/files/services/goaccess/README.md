# GoAccess Access Logs

This service provides visualization for Caddy access logs.

## Configuration

- **log-converter**: `caddylog`, a static Go binary (source: `tools/cmd/caddylog`), converts Caddy's JSON access logs into GoAccess's flat log format. Processes rotated logs once on startup, then tails `access.log` every 10s.
- **goaccess**: reads the converted log and serves a real-time HTML report over WebSocket on port 7890.
- **html-server**: nginx serves the static report snapshot.
- **Logs**: Mounts `/var/log/caddy` from the host (read-only).

Rebuild the binary after changing `tools/cmd/caddylog`:
`cd tools && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../services/goaccess/caddylog ./cmd/caddylog`
(then copy it into `openvox/modules/roles/files/services/goaccess/` too).

## Access

The dashboard is available at `https://logs.mljr.eu`.
