# Homelab Automation

Ansible automation for deploying and managing self-hosted services across the `mljr.eu` homelab over Tailscale.

## Quick Start

```bash
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation
git config core.hooksPath .githooks

pip install ansible-core mitogen ansible-mitogen
ansible-galaxy collection install -r ansible/requirements.yml

# Create encrypted secret store (see vault.yml.example for required variables)
ansible-vault create ansible/inventory/group_vars/all/vault.yml

# Dry run — verifies connectivity and vault decryption
make deploy-check
```

## Architecture

```
GitHub Actions / local Ansible
             |
        Tailscale VPN
             |
   +---------+---------+---------+---------+
   |                   |         |         |
 mljr                nuc       nas       ugreen
 VPS                 compute   Unraid    Debian NAS (UGOS)
 Caddy ingress       node      NAS       backup target,
 CrowdSec            Grafana,  mostly    light read-only
                      Netronome manual   monitoring only
```

NAS/Unraid services are mostly managed manually and only proxied or monitored where explicitly configured. `ugreen` is not a general deployment target - it only receives host-facts-endpoint, Grafana Alloy, iperf3, and (when `ugreen_enabled`) the SFTP backup target.

## Features

- Idempotent Ansible deployments for Rocky Linux hosts.
- Generic Docker Compose service deployment from `services/<name>/docker-compose.yml`.
- Automatic Caddy HTTPS and reverse proxy snippets.
- Staging deployments through `services/<name>/dev/docker-compose.yml`.
- Cleanup of disabled or moved services to avoid stale containers and Caddy snippets.
- Weekly Docker image/container pruning during scheduled deployments.
- Grafana/Loki/VictoriaMetrics monitoring with Grafana Alloy agents.
- CrowdSec security engine with nftables firewall enforcement on `mljr`.
- Netronome network testing on `nuc`, exposed as `speedtest.mljr.eu`.
- GitHub Actions deployment over Tailscale with secrets stored in Ansible Vault.
- Local deployment via `make deploy-*` targets — no GitHub Actions required.

## Directory Structure

```
homelab-automation/
├── AGENTS.md                         # Agent/operator guidance
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/all/
│   │       ├── all.yml               # Service catalog and global config
│   │       ├── secrets.yml           # Maps vault_* vars to secrets.* namespace
│   │       ├── vault.yml             # Ansible Vault encrypted secrets (git-tracked)
│   │       └── vault.yml.example     # Template for creating vault.yml
│   ├── playbooks/site.yml            # Main deployment playbook
│   └── roles/
│       ├── base/
│       ├── caddy/
│       ├── services/
│       ├── container-reconcile/
│       ├── crowdsec-firewall-bouncer/
│       ├── grafana-alloy/                 # rocky + ugreen
│       ├── host-facts-endpoint/           # managed + ugreen
│       ├── healthreport/                  # nuc
│       ├── backup/                        # rocky, borg-based
│       ├── unraid-backup/                 # nas, rclone to pCloud/ugreen
│       ├── backup-remote-key/             # nuc
│       ├── backup-remote-target/          # ugreen, SFTP chroot
│       └── ...
├── services/
│   ├── crowdsec/
│   ├── grafana/
│   ├── speedtest/                    # Netronome
│   └── ...
└── .github/workflows/
    ├── deploy.yml
    └── deploy.yml
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

## Secrets Management

All secrets are stored in `ansible/inventory/group_vars/all/vault.yml`, encrypted with Ansible Vault. The file is committed to git — only the encrypted ciphertext is ever stored.

```bash
# Create vault (first time)
ansible-vault create ansible/inventory/group_vars/all/vault.yml

# Edit secrets
ansible-vault edit ansible/inventory/group_vars/all/vault.yml

# View without editing
ansible-vault view ansible/inventory/group_vars/all/vault.yml
```

See `vault.yml.example` for the full list of required variables with generation hints.

CI requires one GitHub secret: `ANSIBLE_VAULT_PASSWORD`. Tailscale OAuth secrets (`TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`) also stay as GitHub secrets since they are used by the Tailscale GitHub Action, not Ansible.

The pre-commit hook rejects any commit where `vault.yml` is not encrypted.

## Security

CrowdSec replaced fail2ban as the active security stack.

- Dockerized CrowdSec runs on `mljr`.
- The web UI is exposed through Caddy and protected with Authelia.
- `crowdsec-firewall-bouncer-nftables` is installed on `mljr` by Ansible for host-level enforcement.
- Fail2ban is no longer managed by this playbook.

## Monitoring

SigNoz has been replaced by a Grafana stack on `nuc`:

- Grafana UI
- VictoriaMetrics for metrics (PromQL-compatible, 10y retention; accepts Prometheus remote_write on host port 19090)
- Loki for logs
- Grafana Alloy agents on Rocky hosts

Alloy collects host metrics, Docker metrics, Docker logs, Caddy logs, and CrowdSec metrics. NAS/Unraid monitoring is manual. `ugreen` also runs Alloy plus a read-only facts endpoint that reports mdraid/LVM/btrfs storage health, feeding into the health report alongside Unraid's own array/SMART checks.

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

## Ansible Map

Generate a static Markdown/Mermaid map of inventory groups, hosts, and service placement:

```bash
make docs-ansible-map
```

The output is written to `docs/ansible-map.md`.

## ARA Reports

Download the latest completed deployment ARA artifact and open the local ARA web UI:

```bash
make view-ara
```

Use `RUN_ID=<github run id>` to inspect a specific deployment.

## Common Commands

```bash
# Dry run — verify vault decryption and connectivity before touching anything
make deploy-check

# Full deploy
make deploy

# Scoped deploys
make deploy-caddy       # Caddy only (fast)
make deploy-services    # Services only
make deploy-mljr        # All roles, mljr only
make deploy-nuc         # All roles, nuc only

# Pass extra args via the script directly
./scripts/deploy-local.sh --tags services --extra-vars "changed_services=grafana"
./scripts/deploy-local.sh --limit mljr --tags services --extra-vars "force_redeploy=true"
```

## GitHub Actions

The main workflow deploys on pushes to main branches, pull requests in check mode, manual dispatch, and repository dispatch from external repos. Secrets are decrypted from `vault.yml` using the `ANSIBLE_VAULT_PASSWORD` GitHub secret.

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
3. If the service needs secrets: add `vault_*` variables to `vault.yml` (`ansible-vault edit`), then add mappings to `secrets.yml`.
4. Add `services/<name>/dev/docker-compose.yml` if staging is needed.
5. Run `make test`.

## License

MIT License
