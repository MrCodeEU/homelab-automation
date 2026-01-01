# Homelab Automation

Ansible-based automation for deploying and managing self-hosted services across multiple hosts over Tailscale VPN.

## Quick Start

```bash
# Clone and setup
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation/ansible

# Install Ansible collections
ansible-galaxy collection install -r requirements.yml

# Configure your hosts in inventory/hosts.yml
# Configure services in inventory/group_vars/all.yml

# Deploy
ansible-playbook playbooks/site.yml
```

## Architecture

```
GitHub Actions (deploy.yml)
         │ Tailscale VPN
         ▼
    ┌─────────┐     ┌─────────┐     ┌─────────┐
    │  mljr   │     │   pi    │     │   nas   │
    │  (VPS)  │     │  (RPi)  │     │(Unraid) │
    │  Rocky  │     │ proxy   │     │ proxy   │
    └─────────┘     └─────────┘     └─────────┘
```

## Features

- **Idempotent Deployment** - Safe to run repeatedly
- **Staging Environment** - Port offset (+10000) for dev versions
- **Auto-Restore** - Fresh installs automatically restore from backup
- **External Triggers** - Repository dispatch for external service updates
- **Caddy Proxy** - Automatic HTTPS for all services
- **Secret Management** - Centralized secrets via environment variables

## Directory Structure

```
homelab-automation/
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml           # Host definitions
│   │   └── group_vars/
│   │       ├── all.yml         # Services & global config
│   │       └── secrets.yml     # Secret lookups (DRY)
│   ├── playbooks/
│   │   └── site.yml            # Main playbook
│   └── roles/
│       ├── base/               # System + Docker
│       ├── caddy/              # Reverse proxy
│       ├── services/           # Docker Compose
│       ├── backup/             # Automated backup
│       ├── fail2ban/           # Security
│       ├── glance/             # Dashboard
│       └── mailcow/            # Mail server
├── services/                   # Service configurations
│   ├── nightscout/
│   ├── homepage/
│   ├── kuma/
│   └── ...
└── .github/workflows/
    └── deploy.yml              # CI/CD workflow
```

## Service Configuration

Services are defined in `ansible/inventory/group_vars/all.yml`:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.mljr.eu"
    port: 1337
    host: mljr
    staging: true              # Enable staging environment
    caddy_auth: "basicauth"    # Password protection

  - name: homeassistant
    enabled: true
    managed: false             # External service (proxy only)
    domain: "home.mljr.eu"
    port: 8123
    host: pi
```

### Service Options

| Option | Description |
|--------|-------------|
| `enabled` | Deploy this service |
| `managed` | If false, only configure Caddy |
| `staging` | Deploy staging version on dev subdomain |
| `skip_deploy` | Use dedicated role instead |
| `caddy_auth` | Set to "basicauth" for auth |

## Staging Environment

Services with `staging: true` get a staging version:
- **Production**: `service.mljr.eu` on port 1337
- **Staging**: `service.dev.mljr.eu` on port 11337

Staging auto-enables on non-main branches.

## Backup & Restore

Backups run daily at 3 AM to pCloud:
- Docker volumes
- Service data directories

**Auto-restore on fresh install**: Delete `/opt/.homelab-initialized` to trigger restore.

```bash
# Manual restore
/opt/backups/scripts/restore.sh --service nightscout

# List available backups
/opt/backups/scripts/restore.sh --list
```

## Commands

```bash
# Full deployment
ansible-playbook playbooks/site.yml

# Specific host
ansible-playbook playbooks/site.yml --limit mljr

# Specific tags
ansible-playbook playbooks/site.yml --tags caddy,services

# Staging mode
ansible-playbook playbooks/site.yml -e is_staging_deployment=true

# Dry run
ansible-playbook playbooks/site.yml --check
```

## GitHub Actions

The workflow triggers on:
- Push to main/v2 branches
- Manual dispatch with options
- Repository dispatch from external repos

### Trigger from External Repo

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{"event_type": "service-update"}'
```

### Required Secrets

| Secret | Description |
|--------|-------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |
| `NIGHTSCOUT_API_SECRET` | Nightscout API secret |
| `CADDY_AUTH_PASSWORD_HASH` | Bcrypt hash for basicauth |
| `PCLOUD_TOKEN` | pCloud rclone token for backups |

## Adding a Service

1. Add to `ansible/inventory/group_vars/all.yml`:
```yaml
- name: myservice
  enabled: true
  domain: "myservice.mljr.eu"
  port: 8080
  host: mljr
```

2. Create `services/myservice/docker-compose.yml`:
```yaml
services:
  myservice:
    image: myimage:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
```

3. Deploy:
```bash
ansible-playbook playbooks/site.yml --tags services
```

## License

MIT License
