# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Overview

This repository automates the `mljr.eu` homelab with Ansible. Managed Rocky Linux hosts are connected over Tailscale and receive base OS configuration, Docker Compose services, Caddy reverse proxy config, monitoring agents, backup setup, and security enforcement through GitHub Actions or local Ansible runs.

## Initial Setup

After cloning the repository, run:

```bash
git config core.hooksPath .githooks
cd ansible
ansible-galaxy collection install -r requirements.yml
```

Mitogen is enabled in `ansible/ansible.cfg` for faster deployments. Install it locally:

```bash
pip install mitogen ansible-mitogen
```

If Mitogen is unavailable, Ansible may fail before running tasks. Temporarily disable it by commenting out the Mitogen strategy in `ansible/ansible.cfg`.

## Validation

Use the repo test target before handing off changes:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_HOME=/tmp/ansible-home make test
```

The pre-commit hook validates service definitions, Caddy template rendering, Ansible syntax, and Docker Compose syntax. Run it directly with:

```bash
./.githooks/pre-commit
```

The hook creates `.githooks/.venv` automatically. Do not bypass it by running the validation script directly unless debugging the hook itself.

## Commands

Run these from `ansible/` unless noted otherwise:

```bash
# Deploy all
ansible-playbook playbooks/site.yml

# Deploy a specific host
ansible-playbook playbooks/site.yml --limit mljr

# Deploy specific tags
ansible-playbook playbooks/site.yml --tags caddy,services

# Dry run
ansible-playbook playbooks/site.yml --check --diff

# Staging deployment for services with services/<name>/dev/docker-compose.yml
ansible-playbook playbooks/site.yml -e is_staging_deployment=true

# Deploy only changed services
ansible-playbook playbooks/site.yml -e changed_services=nightscout,homepage

# Force full service file sync and .env regeneration
ansible-playbook playbooks/site.yml --tags services -e force_redeploy=true

# Force Caddy snippet regeneration
ansible-playbook playbooks/site.yml --tags caddy -e force_regen_caddy=true

# Run Docker image/container pruning
ansible-playbook playbooks/site.yml --tags prune -e docker_prune_enabled=true
```

## Architecture

### Hosts

```yaml
managed:
  rocky:     # Full Ansible control: mljr, nuc
  unraid:    # Partial: most NAS apps stay manual (Unraid UI), but catalog
             # entries marked `managed: true` are deployed by the Unraid play
proxy_only:  # Caddy-only routing targets
```

The NAS is partially managed. `inventory/group_vars/unraid.yml` sets
`base_path: /mnt/user/appdata/homelab` (because `/` is tmpfs) and, critically,
`cleanup_enabled: false` so orphan cleanup can never remove UI-created
containers. `roles/unraid-bootstrap` installs a User Scripts entry that runs at
array start to restore compose projects, helper binaries and registry
credentials after the tmpfs root is rebuilt. Do not "correct" the
`managed: true` NAS entries back to false.

`mljr` is the public ingress and critical infrastructure host. `nuc` is the stronger compute node and hosts heavier internal services such as Grafana and Netronome.

### Key Files

| File | Purpose |
|------|---------|
| `ansible/inventory/group_vars/all/all.yml` | Service catalog and global settings |
| `ansible/inventory/group_vars/all/secrets.yml` | Vault variable mappings |
| `ansible/inventory/hosts.yml` | Host and Tailscale target definitions |
| `ansible/playbooks/site.yml` | Main playbook and role order |
| `ansible/roles/services/` | Generic Docker Compose deployment role |
| `services/<name>/docker-compose.yml` | Service Compose definitions |

## Service Catalog

Services are defined in `ansible/inventory/group_vars/all/all.yml`:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.mljr.eu"  # string or list
    port: 1337                    # use 0 for no web UI
    host: nuc                     # inventory hostname
    managed: true                 # false means Caddy proxy only
    caddy_auth: "authelia"        # "basicauth" or "authelia"
    skip_deploy: false            # true means a dedicated role owns it
    backup_critical: true
    requires_sysctl: "key=value"
    https_backend: true
    description: "Human-readable description"
    icon: "mdi:icon-name"
```

The services role only deploys enabled, managed services that are not marked `skip_deploy`. Disabled services remain in the catalog so cleanup and Caddy reconciliation can remove old containers and snippets idempotently.

## Deployment Flow

The main playbook order is:

1. Gather facts
2. Base setup
3. Standalone container reconciliation
4. HetrixTools, backup, dashboard, mail, Authelia
5. Generic Docker services
6. CrowdSec firewall bouncer on `mljr`, when enabled
7. Grafana Alloy, iperf3, Hawser agent
8. Caddy reverse proxy

This order is intentional. The CrowdSec bouncer runs after the Dockerized CrowdSec service is deployed.

## Docker Cleanup

Weekly scheduled GitHub deployments enable `docker_prune_enabled=true`, which prunes unused Docker images and stopped containers but not volumes.

## Security

CrowdSec is the primary security engine. The Dockerized CrowdSec service runs on `mljr`, reads system/Caddy logs, exposes the web UI on `crowdsec.mljr.eu` and `security.mljr.eu`, and creates the firewall bouncer API key from `CROWDSEC_FIREWALL_BOUNCER_KEY`.

Host-level enforcement is handled by `ansible/roles/crowdsec-firewall-bouncer`, which installs `crowdsec-firewall-bouncer-nftables` on `mljr` and points it at the Dockerized CrowdSec LAPI on `127.0.0.1:8088`.

Fail2ban is no longer managed by this playbook. CrowdSec is the active security engine:

```yaml
crowdsec_firewall_bouncer_enabled: true
```

Do not reintroduce fail2ban without also defining its migration and cleanup behavior.

## Monitoring

Grafana replaced SigNoz. The stack lives in `services/grafana/` and is deployed on `nuc`. Grafana Alloy runs on Rocky hosts and forwards host metrics, Docker metrics, Docker logs, Caddy logs, and CrowdSec metrics to the Grafana stack.

The metrics store is VictoriaMetrics (replaced Prometheus): PromQL-compatible, retention 10y, accepts Prometheus `remote_write` natively at `/api/v1/write`. Host port 19090 maps to VM's 8428 so the Alloy remote-write URL in `roles/grafana-alloy/tasks/main.yml` stays unchanged. The Grafana datasource keeps name/uid `prometheus` (pointed at `http://victoriametrics:8428`) so dashboard JSON needs no changes. The mljr.eu homepage also queries this endpoint over Tailscale for its live homelab panel (`HOMELAB_PROM_URL` in `services/homepage/docker-compose.yml`). `services/grafana/prometheus/` is legacy config, kept only until first VM deploy is verified.

Grafana datasources and dashboards are provisioned from the repo. Use stable datasource UIDs `prometheus` and `loki` in dashboard JSON. NAS telemetry is now deployed from `services/nas-alloy/` by the Unraid play (`services/grafana/nas-alloy.example.alloy` is superseded).

Two Alloy details that are easy to get wrong, both fixed in `roles/grafana-alloy/templates/config.alloy.j2`:
- `prometheus.scrape` attaches its own `instance` label from the scrape target, which **wins over** `remote_write`'s `external_labels`. mljr therefore reported as `vmi2945702.contaboserver.net` until a `prometheus.relabel` component was added to force the inventory hostname.
- `loki.source.docker`'s static `labels` block **replaces** everything `discovery.docker` produced, so the container name was lost and Docker logs were unattributable. A `discovery.relabel` promotes `__meta_docker_container_name` to a `container` label first.

## Health Report

`services/healthreport/` is a one-shot container on `nuc`, run by a systemd timer, that collects facts, assigns severity from `services/healthreport/rules.yml`, diffs against the previous run, and sends a report via ntfy and email. See its README for the design.

Two invariants: severity is decided by the rules file **before** the LLM runs and the model may not change it; and a collector that fails becomes a finding in the report rather than a silent gap. Facts that are not reachable over the network (CrowdSec LAPI, nftables, Unraid array/SMART) come from `roles/host-facts-endpoint` — a read-only script behind an SSH key restricted with `command=`, not an open port.

## Network Testing

`speedtest.mljr.eu` is Netronome, deployed from `services/speedtest/` on `nuc` and proxied through Caddy on `mljr`. Cross-node iperf servers are managed by the `iperf3` role. Netronome targets and schedules are configured in the Netronome UI.

## Authentication

Caddy supports:

| Value | Description |
|-------|-------------|
| `basicauth` | Uses `CADDY_AUTH_USER` and `CADDY_AUTH_PASSWORD_HASH` |
| `authelia` | SSO through Authelia |

Prefer `authelia` for user-facing internal tools.

## Service Hooks

Services can define hook scripts in `services/<name>/hooks/`:

| Hook | When it runs |
|------|-------------|
| `pre-deploy.sh` | Before deployment |
| `post-deploy.sh` | After Docker Compose deployment |
| `validate.sh` | Service validation |

Register every `post-deploy.sh` in `post_deploy_hook_services` in `all.yml`; otherwise the services role warns and skips the hook. Hooks load `.env` with the role's dotenv parser, so secrets containing shell-special characters are handled safely.

## Staging

Staging is opt-in by creating `services/<name>/dev/docker-compose.yml`. When `is_staging_deployment=true`, staging services deploy to `staging_host` (`nuc`) and Caddy proxies `<service>.dev.mljr.eu` to the explicit port from the dev Compose file. Use the production port plus `10000` unless there is a strong reason not to.

## Secrets

Secrets are mapped from Ansible Vault variables in `ansible/inventory/group_vars/all/secrets.yml`:

```yaml
secrets:
  grafana:
    admin_password: "{{ vault_grafana_admin_password | default('') }}"
```

When adding a secret-backed service, update `secrets.yml`, `vault.yml.example`, and `.github/workflows/README.md`.

## Important Tags

| Tag | Description |
|-----|-------------|
| `base` | System packages and Docker |
| `prune` | Docker image/container pruning |
| `services` | Generic Docker Compose services |
| `caddy` | Reverse proxy configuration |
| `security` | CrowdSec security tasks |
| `crowdsec` | CrowdSec firewall bouncer tasks |
| `grafana-alloy` | Metrics/log collection agent |
| `monitoring` | Monitoring-related roles |
| `iperf3` | Network performance test server |
| `hawser-agent` | Remote Docker management agent |
| `backup` | Backup and restore configuration |
| `glance` | Dashboard |
| `mailcow` | Mail server |
| `authelia` | SSO identity provider |
