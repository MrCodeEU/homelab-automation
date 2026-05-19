# Homelab Automation

Ansible automation for deploying and managing self-hosted services across the `mljr.eu` homelab over Tailscale.

## Quick Start

```bash
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation
git config core.hooksPath .githooks

cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml
```

## Architecture

```
GitHub Actions / local Ansible
             |
        Tailscale VPN
             |
   +---------+---------+
   |                   |
 mljr                nuc
 VPS                 compute node
 Caddy ingress       Grafana, Netronome,
 CrowdSec            heavier services
```

NAS/Unraid services are mostly managed manually and only proxied or monitored where explicitly configured.

## Features

- Idempotent Ansible deployments for Rocky Linux hosts.
- Generic Docker Compose service deployment from `services/<name>/docker-compose.yml`.
- Automatic Caddy HTTPS and reverse proxy snippets.
- Staging deployments through `services/<name>/dev/docker-compose.yml`.
- Cleanup of disabled or moved services to avoid stale containers and Caddy snippets.
- Weekly Docker image/container pruning during scheduled deployments.
- Grafana/Loki/Prometheus monitoring with Grafana Alloy agents.
- CrowdSec security engine with nftables firewall enforcement on `mljr`.
- Netronome network testing on `nuc`, exposed as `speedtest.mljr.eu`.
- GitHub Actions deployment over Tailscale with secrets injected as environment variables.

## Directory Structure

```
homelab-automation/
├── AGENTS.md                         # Agent/operator guidance
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/all/
│   │       ├── all.yml               # Service catalog and global config
│   │       └── secrets.yml           # Environment variable lookups
│   ├── playbooks/site.yml            # Main deployment playbook
│   └── roles/
│       ├── base/
│       ├── caddy/
│       ├── services/
│       ├── container-reconcile/
│       ├── crowdsec-firewall-bouncer/
│       ├── fail2ban-retire/
│       ├── grafana-alloy/
│       └── ...
├── services/
│   ├── crowdsec/
│   ├── grafana/
│   ├── speedtest/                    # Netronome
│   └── ...
└── .github/workflows/
    ├── deploy.yml
    └── deploy-parallel.yml
```

## Service Configuration

Services are defined in `ansible/inventory/group_vars/all/all.yml`:

```yaml
services:
  - name: myservice
    enabled: true
    domain: "myservice.mljr.eu"
    port: 8080
    host: nuc
    managed: true
    caddy_auth: "authelia"
```

Important options:

| Option | Description |
|--------|-------------|
| `enabled` | Whether the service should exist |
| `managed` | If false, only Caddy proxy config is generated |
| `skip_deploy` | Dedicated role owns deployment |
| `domain` | String or list of domains |
| `port` | Backend port, or `0` for notification-only/no UI services |
| `host` | Inventory host running the service |
| `caddy_auth` | `basicauth` or `authelia` |

Disabled services can remain in the catalog so cleanup roles can remove old deployments and stale proxy snippets safely.

## Key Services

| Service | Host | Domain |
|---------|------|--------|
| Caddy | `mljr` | Public ingress for `*.mljr.eu` |
| Authelia | `mljr` | `auth.mljr.eu` |
| CrowdSec | `mljr` | `crowdsec.mljr.eu`, `security.mljr.eu` |
| Grafana | `nuc` | `monitor.mljr.eu`, `grafana.mljr.eu` |
| Netronome | `nuc` | `speedtest.mljr.eu` |
| Dozzle | `nuc` | `docker.mljr.eu` |

## Security

CrowdSec replaced fail2ban as the active security stack.

- Dockerized CrowdSec runs on `mljr`.
- The web UI is exposed through Caddy and protected with Authelia.
- `crowdsec-firewall-bouncer-nftables` is installed on `mljr` by Ansible for host-level enforcement.
- The `fail2ban-retire` role stops/removes old fail2ban state only after the CrowdSec bouncer is active.

Required CrowdSec secrets:

| Secret | Description |
|--------|-------------|
| `CROWDSEC_WEB_UI_PASSWORD` | CrowdSec web UI machine password |
| `CROWDSEC_WEB_UI_NOTIFICATION_SECRET` | CrowdSec web UI notification encryption secret |
| `CROWDSEC_FIREWALL_BOUNCER_KEY` | API key for the host firewall bouncer |
| `NETRONOME_ADMIN_PASSWORD` | Netronome admin user password |
| `NETRONOME_SESSION_SECRET` | Netronome session signing secret |

## Monitoring

SigNoz has been replaced by a Grafana stack on `nuc`:

- Grafana UI
- Prometheus for metrics
- Loki for logs
- Grafana Alloy agents on Rocky hosts

Alloy collects host metrics, Docker metrics, Docker logs, Caddy logs, and CrowdSec metrics. NAS/Unraid monitoring is manual.

Grafana provisioning is stored in `services/grafana/`:

- Datasources: `services/grafana/provisioning/datasources/datasources.yml`
- Dashboard provider: `services/grafana/provisioning/dashboards/dashboards.yml`
- Dashboards: `services/grafana/dashboards/*.json`
- Manual NAS Alloy example: `services/grafana/nas-alloy.example.alloy`

Once the NAS sends metrics/logs with `instance="nas"` and `host="nas"`, the provisioned dashboards include it automatically.

## Staging

Create `services/<name>/dev/docker-compose.yml` to make a service staging-capable. Then run:

```bash
ansible-playbook playbooks/site.yml -e is_staging_deployment=true
```

Staging services deploy to `staging_host` (`nuc`) and are proxied as `<service>.dev.mljr.eu`.

## Validation

From the repository root:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_HOME=/tmp/ansible-home make test
```

This runs service validation, Caddy template rendering, Ansible syntax checks, and Docker Compose syntax checks.

## Common Commands

```bash
cd ansible

# Full deployment
ansible-playbook playbooks/site.yml

# Specific host
ansible-playbook playbooks/site.yml --limit mljr

# Specific tags
ansible-playbook playbooks/site.yml --tags services,caddy

# Dry run
ansible-playbook playbooks/site.yml --check --diff

# Force service file sync and .env regeneration
ansible-playbook playbooks/site.yml --tags services -e force_redeploy=true
```

## GitHub Actions

The main workflow deploys on pushes to main branches, pull requests in check mode, manual dispatch, and repository dispatch from external repos. Secrets are injected as environment variables and consumed through `ansible/inventory/group_vars/all/secrets.yml`.

External repos can trigger a specific service deployment with `repository_dispatch`:

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{
        "event_type": "service-update",
        "client_payload": {
          "service": "homepage",
          "environment": "production",
          "commit_sha": "${{ github.sha }}"
        }
      }'
```

## Adding a Service

1. Add the service to `ansible/inventory/group_vars/all/all.yml`.
2. Create `services/<name>/docker-compose.yml`.
3. Add any secret lookups to `ansible/inventory/group_vars/all/secrets.yml`.
4. Inject new GitHub secrets in `.github/workflows/deploy.yml` and document them in `.github/workflows/README.md`.
5. Add `services/<name>/dev/docker-compose.yml` if staging is needed.
6. Run `make test`.

## License

MIT License
