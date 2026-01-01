# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Overview

Homelab automation using **Ansible** to deploy and manage self-hosted services across multiple hosts connected via Tailscale VPN. The system supports Rocky Linux servers with automated deployment through GitHub Actions.

## Architecture

### Directory Structure

```
homelab-automation/
├── .github/workflows/
│   └── deploy.yml           # Main CI/CD workflow
├── ansible/
│   ├── ansible.cfg          # Ansible configuration
│   ├── requirements.yml     # Galaxy collections
│   ├── inventory/
│   │   ├── hosts.yml        # Host definitions
│   │   └── group_vars/
│   │       ├── all.yml      # Services and global vars
│   │       └── secrets.yml  # Secret lookups (DRY)
│   ├── playbooks/
│   │   └── site.yml         # Main playbook
│   └── roles/
│       ├── base/            # System packages + Docker
│       ├── caddy/           # Reverse proxy
│       ├── services/        # Docker Compose deployment
│       ├── backup/          # Automated backup/restore
│       ├── fail2ban/        # Security
│       ├── glance/          # Dashboard
│       └── mailcow/         # Mail server
├── services/                # Service configurations
│   ├── nightscout/
│   ├── homepage/
│   ├── kuma/
│   └── ...
└── Makefile
```

### Host Groups

```yaml
managed:
  rocky:    # Rocky Linux (mljr)
  unraid:   # Unraid NAS (nas)
proxy_only: # Caddy config only (pi, nuc, monitoring)
```

### Service Definition

Services are defined in `ansible/inventory/group_vars/all.yml`:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.mljr.eu"
    port: 1337
    host: mljr
    description: "CGM Monitor"
    icon: "mdi:diabetes"
    staging: true           # Enable staging environment
    caddy_auth: "basicauth" # Password protection
    managed: false          # External service (proxy only)
    skip_deploy: true       # Uses dedicated role
```

### Staging Environment

When `staging: true` on a service:
- Production: `service.mljr.eu` on port (e.g., 1337)
- Staging: `service.dev.mljr.eu` on port + 10000 (e.g., 11337)

Staging is auto-enabled on non-main branches or via workflow dispatch.

### Secrets

Secrets are centralized in `secrets.yml` using environment lookups:

```yaml
secrets:
  nightscout:
    api_secret: "{{ lookup('env', 'NIGHTSCOUT_API_SECRET') }}"
  caddy:
    auth_user: "{{ lookup('env', 'CADDY_AUTH_USER') }}"
```

## Commands

```bash
# Deploy all
cd ansible && ansible-playbook playbooks/site.yml

# Deploy specific host
ansible-playbook playbooks/site.yml --limit mljr

# Deploy specific tags
ansible-playbook playbooks/site.yml --tags caddy,services

# Dry run
ansible-playbook playbooks/site.yml --check

# Staging deployment
ansible-playbook playbooks/site.yml -e is_staging_deployment=true
```

## Adding a New Service

1. Add to `all.yml`:
```yaml
- name: myservice
  enabled: true
  domain: "myservice.mljr.eu"
  port: 8080
  host: mljr
```

2. Create `services/myservice/docker-compose.yml`

3. Deploy:
```bash
ansible-playbook playbooks/site.yml --limit mljr --tags services
```

## Backup & Restore

- Backups run daily at 3 AM via systemd timer
- Stored in pCloud via rclone
- Auto-restore on fresh install (checks `/opt/.homelab-initialized`)

Manual restore:
```bash
/opt/backups/scripts/restore.sh --service nightscout
```

## Triggering Deployment from External Repos

Add to your public repo's workflow:

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{"event_type": "service-update", "client_payload": {"service": "homepage"}}'
```

## Ansible Tags

| Tag | Description |
|-----|-------------|
| base | System packages, Docker |
| caddy | Reverse proxy |
| services | Docker Compose services |
| backup | Backup configuration |
| security | Fail2ban |
| glance | Dashboard |
| mailcow | Mail server |
