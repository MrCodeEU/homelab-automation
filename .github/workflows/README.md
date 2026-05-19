# GitHub Actions Deployment Workflows

This directory contains the GitHub Actions workflows for deploying the homelab with Ansible over Tailscale.

## Workflows

### Standard Deploy (`deploy.yml`)

Sequential deployment with validation, change detection, Ansible execution, summary generation, and ntfy notification.

It runs in check mode for pull requests and can deploy changed services only when the git diff is narrow enough.

### Parallel Deploy (`deploy-parallel.yml`)

Manual workflow that deploys hosts in parallel for better visibility and faster multi-host runs.

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Tailscale Authentication
| Secret | Description |
|--------|-------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |

**Setup:**
1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Generate OAuth client credentials
3. Add tag `tag:ci` to the OAuth client permissions

### Application Secrets
| Secret | Description |
|--------|-------------|
| `NIGHTSCOUT_API_SECRET` | Nightscout API authentication secret |
| `LINK_UP_USERNAME` | LibreLink Up account username |
| `LINK_UP_PASSWORD` | LibreLink Up account password |
| `NIGHTSCOUT_API_TOKEN` | Nightscout API token |
| `NIGHTSCOUT_DOMAIN` | Nightscout domain (e.g., `nightscout.example.com`) |
| `BICHON_ENCRYPT_PASSWORD` | Bichon email archiver encryption password |
| `CADDY_AUTH_PASSWORD_HASH` | Bcrypt hash for Caddy basicauth |
| `CADDY_AUTH_USER` | Username for Caddy basicauth |
| `GRAFANA_ADMIN_USER` | Grafana admin user (optional, defaults to `admin`) |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |
| `CROWDSEC_WEB_UI_PASSWORD` | CrowdSec machine password for the web UI |
| `CROWDSEC_WEB_UI_NOTIFICATION_SECRET` | CrowdSec web UI notification encryption key |
| `CROWDSEC_FIREWALL_BOUNCER_KEY` | CrowdSec firewall bouncer API key for host-level remediation |
| `NETRONOME_ADMIN_PASSWORD` | Netronome admin user password |
| `NETRONOME_SESSION_SECRET` | Netronome session signing secret (optional but recommended) |

## How It Works

```
┌─────────────────────┐
│  GitHub Actions     │
│  Runner (Ubuntu)    │
└──────────┬──────────┘
           │
           │ 1. Install Ansible
           │ 2. Set up Tailscale VPN
           ▼
┌─────────────────────┐
│  Tailscale Network  │
└──────────┬──────────┘
           │
           │ 3. Run ansible-playbook
           ▼
┌─────────────────────┐
│  Target Hosts       │
│  (mljr/nuc/nas)     │
└─────────────────────┘
```

**Workflow steps:**
1. Checkout repository
2. Set up Tailscale VPN connection
3. Install Ansible (cached)
4. Install Ansible collections
5. Inject secrets as environment variables
6. Run `ansible-playbook playbooks/site.yml` with selected limit/tags/check mode
7. Fail the job when Ansible fails and send deployment notification

## Ansible Roles (Tags)

| Tag | Description | Hosts |
|-----|-------------|-------|
| `base` | Install base packages and Docker | rocky |
| `services` | Deploy Docker Compose services | rocky |
| `caddy` | Configure Caddy reverse proxy | mljr |
| `security` | Security setup, CrowdSec bouncer, fail2ban retirement | mljr/rocky |
| `crowdsec` | CrowdSec firewall bouncer | mljr |
| `fail2ban` | Legacy fail2ban setup/retirement | rocky |
| `grafana-alloy` | Monitoring agent | rocky |
| `monitoring` | Monitoring-related roles | rocky |
| `backup` | Backup/restore setup | rocky |

## Security Features

- **No SSH keys in repository**: Uses Tailscale authentication
- **Ephemeral connections**: VPN exists only during workflow run
- **Scoped permissions**: OAuth client tagged with `tag:ci`
- **Secrets as env vars**: Injected via Ansible `lookup('env', ...)`
- **No public exposure**: All communication over private Tailscale network
- **CrowdSec enforcement**: `mljr` installs the nftables firewall bouncer before fail2ban is retired

## Troubleshooting

### "Cannot connect to host"
- Verify Tailscale is running on target device
- Check hostname in `ansible/inventory/hosts.yml`
- Ensure `tag:ci` is allowed in your Tailscale ACLs

### "Permission denied"
- Verify user has sudo/root permissions
- Check `ansible_user` in inventory

### "Module not found"
- Run `ansible-galaxy collection install -r requirements.yml`

## Example Usage

### Deploy everything to all hosts:
```bash
# Via GitHub Actions: select limit=all, tags=all
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml
```

### Deploy only to VPS:
```bash
# Via GitHub Actions: select limit=mljr
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --limit mljr
```

### Deploy only Caddy configuration:
```bash
# Via GitHub Actions: select tags=caddy
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --tags caddy
```

### Deploy services to specific host:
```bash
cd ansible && ansible-playbook playbooks/site.yml --limit mljr --tags services
```
