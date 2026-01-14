# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Homelab automation using **Ansible** to deploy and manage self-hosted services across multiple hosts connected via Tailscale VPN. The system supports Rocky Linux servers with automated deployment through GitHub Actions.

## Commands

```bash
# From ansible/ directory:

# Deploy all
ansible-playbook playbooks/site.yml

# Deploy specific host
ansible-playbook playbooks/site.yml --limit mljr

# Deploy specific tags
ansible-playbook playbooks/site.yml --tags caddy,services

# Dry run (what PRs and non-main branches do automatically)
ansible-playbook playbooks/site.yml --check --diff

# Staging deployment (port +10000, dev subdomain)
ansible-playbook playbooks/site.yml -e is_staging_deployment=true

# Install Ansible collections
ansible-galaxy collection install -r requirements.yml
```

## Architecture

### Host Groups

```yaml
managed:
  rocky:       # Rocky Linux - full deployment (mljr)
  unraid:      # Unraid NAS (nas) - limited management
proxy_only:    # Caddy config only, not SSH-reachable (pi, nuc, monitoring)
```

### Key Files

| File | Purpose |
|------|---------|
| `ansible/inventory/group_vars/all/all.yml` | Service definitions, global config |
| `ansible/inventory/group_vars/all/secrets.yml` | Environment variable lookups |
| `ansible/inventory/hosts.yml` | Host definitions with Tailscale hostnames |
| `ansible/playbooks/site.yml` | Main playbook with tag documentation |
| `services/<name>/docker-compose.yml` | Service Docker configurations |

### Service Definition

Services in `ansible/inventory/group_vars/all/all.yml`:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.mljr.eu"  # Can be string or list
    port: 1337
    host: mljr                    # Must match inventory hostname
    staging: true                 # Deploy staging version to staging_host
    caddy_auth: "basicauth"       # Password protection
    managed: false                # External service (proxy only, no docker-compose)
    skip_deploy: true             # Uses dedicated role instead of services role
    backup_critical: true         # Restore on fresh install
```

### Staging Environment

- All staging services deploy to `staging_host` (nuc) regardless of their `host` property
- Port offset: +10000 (e.g., 1337 → 11337)
- Domain: `service.dev.mljr.eu`
- Path: `/opt/staging/<service>`
- Caddy on mljr proxies staging domains to nuc

### Secrets Pattern

All secrets use environment variable lookups in `secrets.yml`:

```yaml
secrets:
  nightscout:
    api_secret: "{{ lookup('env', 'NIGHTSCOUT_API_SECRET') }}"
```

Reference in templates: `{{ secrets.nightscout.api_secret }}`

## Deployment Flow

1. **GitHub Actions** triggers on push to main, PRs (check mode), or repository dispatch
2. **Tailscale VPN** connects runner to hosts
3. **Playbook execution**: base → security → backup → glance → mailcow → services → caddy

### Async Deployment

The `services` role deploys Docker Compose services asynchronously for parallel execution, then waits for completion. Health checks also run in parallel.

### Check Mode

PRs and non-main branches automatically run with `--check --diff` (dry run). This validates changes without applying them.

## Adding a New Service

1. Add service definition to `ansible/inventory/group_vars/all/all.yml`
2. Create `services/<name>/docker-compose.yml`
3. If service needs secrets, add env lookups to `secrets.yml` and GitHub Actions secrets
4. Deploy: `ansible-playbook playbooks/site.yml --tags services`

## Ansible Tags

| Tag | Description |
|-----|-------------|
| base | System packages, Docker |
| caddy | Reverse proxy (always runs last) |
| services | Docker Compose services |
| beszel-agent | Beszel monitoring agent (all rocky hosts) |
| monitoring | Alias for beszel-agent |
| backup | Backup/restore configuration |
| security | Fail2ban |
| glance | Dashboard |
| mailcow | Mail server |

## Triggering Deployment from External Repos

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{"event_type": "service-update"}'
```

Repository dispatch automatically uses `--tags services,caddy`.
