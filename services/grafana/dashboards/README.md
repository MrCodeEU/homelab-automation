# Grafana Dashboards

Dashboard JSON files in this directory are provisioned into the `Homelab`
folder on container start and refreshed by Grafana every 30 seconds.

Provisioned datasources use stable UIDs:

- `prometheus`
- `loki`

## Current Dashboards

- `homelab-overview.json`: Host, Docker, storage, network, and recent logs.
- `homelab-security.json`: CrowdSec decisions, alerts, SSH/Caddy activity, and security logs.

## NAS / Unraid

NAS metrics and logs will appear automatically once a manually installed Alloy
or compatible Prometheus/Loki agent writes to:

- Prometheus remote write: `http://100.100.10.1:19090/api/v1/write`
- Loki push API: `http://100.100.10.1:3100/loki/api/v1/push`

Use `instance="nas"` and `host="nas"` labels so the dashboards pick it up in
the same host variable as `mljr` and `nuc`.
