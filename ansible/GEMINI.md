# Homelab Automation - Ansible

This directory contains the Ansible configuration for the `mljr.eu` homelab. It manages Rocky Linux hosts over Tailscale, deploys Docker Compose services, configures Caddy, runs backups, installs monitoring agents, and enforces security controls.

## Main Components

- `base`: system packages, timezone, Docker, firewalld baseline.
- `services`: generic Docker Compose deployment for the service catalog.
- `container-reconcile`: removes retired standalone containers and paths.
- `caddy`: Caddy reverse proxy, HTTPS, snippets, and log permissions.
- `crowdsec-firewall-bouncer`: installs host nftables remediation on `mljr`.
- `grafana-alloy`: host, Docker, and log telemetry to the Grafana stack.
- `backup`: backup and restore scripts.
- `glance`, `mailcow`, `authelia`: dedicated service roles.

## Key Files

| Path | Purpose |
|------|---------|
| `inventory/hosts.yml` | Inventory hosts and Tailscale addresses |
| `inventory/group_vars/all/all.yml` | Global settings and service catalog |
| `inventory/group_vars/all/secrets.yml` | Vault variable mappings |
| `playbooks/site.yml` | Main playbook and role order |
| `roles/services/` | Generic Docker Compose service deployment |

## Service Catalog

Services live in `inventory/group_vars/all/all.yml`. Each entry controls deployment, Caddy routing, dashboard metadata, staging support, and cleanup.

Common fields:

- `enabled`: whether the service should exist.
- `managed`: if false, only Caddy proxy config is generated.
- `skip_deploy`: a dedicated role owns deployment.
- `domain`: one domain or a list of domains.
- `port`: backend port, or `0` for no web UI.
- `host`: target inventory host.
- `caddy_auth`: `basicauth` or `authelia`.

Disabled services should usually remain in the catalog until cleanup has removed old containers and snippets.

## Playbook Order

`site.yml` is ordered to keep migrations safe:

1. Gather facts
2. Base setup
3. Container reconciliation
4. Infrastructure roles
5. Generic Docker services
6. CrowdSec firewall bouncer on `mljr`
7. Monitoring agents and iperf3
8. Caddy

CrowdSec bouncer setup intentionally runs after the Dockerized CrowdSec service is deployed.

## Security

CrowdSec is active security. Fail2ban is no longer managed by this playbook:

```yaml
crowdsec_firewall_bouncer_enabled: true
```

The `crowdsec` Docker service provides detection and UI. The host bouncer role installs `crowdsec-firewall-bouncer-nftables` on `mljr` and points it to `127.0.0.1:8088`.

Required secrets:

- `CROWDSEC_WEB_UI_PASSWORD`
- `CROWDSEC_WEB_UI_NOTIFICATION_SECRET`
- `CROWDSEC_FIREWALL_BOUNCER_KEY`

## Monitoring

Grafana replaced SigNoz. `grafana-alloy` runs on Rocky hosts and forwards metrics/logs to the Grafana stack on `nuc`. Grafana datasources and dashboards are provisioned from `services/grafana/`. Do not reintroduce SigNoz agents unless intentionally reverting the monitoring stack.

Use stable dashboard datasource UIDs:

- `prometheus`
- `loki`

NAS/Unraid telemetry is manual. `services/grafana/nas-alloy.example.alloy` documents the expected remote-write and Loki endpoints.

## Docker Cleanup

Weekly scheduled deployments enable `docker_prune_enabled=true` so unused Docker images and stopped containers are cleaned up without pruning volumes.

## Network Testing

`speedtest` is Netronome on `nuc`, exposed as `speedtest.mljr.eu`. Cross-node iperf is provided by the `iperf3` role; Netronome targets are configured manually in the UI.

## Usage

```bash
# Deploy everything
ansible-playbook playbooks/site.yml

# Deploy only services and Caddy
ansible-playbook playbooks/site.yml --tags services,caddy

# Limit to one host
ansible-playbook playbooks/site.yml --limit mljr

# Dry run
ansible-playbook playbooks/site.yml --check --diff

# Staging deployment
ansible-playbook playbooks/site.yml -e is_staging_deployment=true
```

## Development Conventions

- Keep tasks idempotent.
- Prefer variables in `group_vars/all/all.yml` over hardcoded values.
- Add secrets through vault variables mapped in `secrets.yml`.
- Update `vault.yml.example` when adding secrets.
- Use Jinja templates for generated config.
- Run the root `make test` target before pushing.
