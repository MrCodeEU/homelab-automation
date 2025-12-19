# GoAccess Access Logs

This service provides visualization for Caddy access logs.

## Configuration

- **Docker Compose**: Runs GoAccess in a loop (every 30s) to generate a static HTML report.
- **Web Server**: Uses `busybox httpd` to serve the report on port 7890.
- **Logs**: Mounts `/opt/caddy/logs` from the host (read-only).

## Access

The dashboard is available at `https://logs.mljr.eu`.
