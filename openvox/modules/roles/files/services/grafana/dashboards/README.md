# Grafana Dashboards

Dashboard JSON files in this directory are provisioned into the `Homelab`
folder on container start and refreshed by Grafana every 30 seconds.

Provisioned datasources use stable UIDs:

- `prometheus`
- `loki`
- `dmarc-postgres` (dmarc-monitor's Postgres, reached over Tailscale - it
  lives in a separate Compose project on `nuc`, see
  `provisioning/datasources/datasources.yml`)

## Current Dashboards

- `homelab-overview.json`: Host, Docker, storage, network, recent logs,
  fleet-wide scrape-target status, and CI-published OpenVox apply state.
- `homelab-security.json`: CrowdSec decisions, alerts, SSH/Caddy activity, and security logs.
- `homelab-storage.json`: SMART health/temperature, systemd failed units,
  btrfs pool usage/errors, and all-mounts disk usage across the fleet.
- `homelab-homeassistant.json`: HA sensor data (temperature, humidity,
  power, energy, illuminance, CO2/VOC, data rates), battery levels sorted
  low-first, unavailable entities, and device trackers. Built for maximal
  coverage of what's currently exported - expect to prune panels that turn
  out to be noise once this has been lived with for a while.
- `homelab-crowdsec.json`: active ban decisions (total and by origin - CAPI's
  community blocklist vs. this box's own local detections, since those are
  very different scales), alert/bucket-overflow rate, top ban reasons.
- `homelab-dmarc.json`: DMARC pass rate, message volume by disposition, top
  sending sources and top failing sources - from dmarc-monitor's parsedmarc
  Postgres database, not Prometheus/Loki like the others.

## NAS / Unraid

NAS metrics and logs will appear automatically once a manually installed Alloy
or compatible Prometheus/Loki agent writes to:

- Prometheus remote write: `http://100.100.10.1:19090/api/v1/write`
- Loki push API: `http://100.100.10.1:3100/loki/api/v1/push`

Use `instance="nas"` and `host="nas"` labels so the dashboards pick it up in
the same host variable as `mljr` and `nuc`.
