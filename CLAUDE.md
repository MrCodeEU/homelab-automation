# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Homelab automation using **Ansible** to deploy and manage self-hosted services across multiple hosts connected via Tailscale VPN. The system supports Rocky Linux servers with automated deployment through GitHub Actions.

## Initial Setup

After cloning the repository, run:
```bash
# Enable pre-commit hooks (validates service configs before each commit)
git config core.hooksPath .githooks
```

### Mitogen (Required)

Mitogen is enabled by default in `ansible.cfg` (`strategy = mitogen_linear`) for 40-70% speed improvement. Install it locally:

```bash
pip install mitogen ansible-mitogen
```

If Mitogen is not installed, Ansible will fail. To disable it temporarily, comment out `strategy = mitogen_linear` in `ansible/ansible.cfg`.

## Pre-commit Validation

The pre-commit hook validates service configurations before each commit. It uses a Python virtual environment at `.githooks/.venv` (auto-created on first run).

**Validations performed:**
- **Port uniqueness**: No two services on the same host can use the same port
- **Domain uniqueness**: Each domain can only be assigned to one service
- **Service name uniqueness**: No duplicate service names
- **Host validation**: Service `host` must exist in inventory
- **Required fields**: `host` and `port` required for enabled managed services
- **Docker-compose exists**: Managed services must have `services/<name>/docker-compose.yml`
- **Staging port convention**: Warns if staging port doesn't follow `production_port + 10000`

**Run manually:** `./.githooks/pre-commit` (sets up venv automatically, do NOT run `validate_services.py` directly)

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

# Staging deployment (deploys services with dev/ folder)
ansible-playbook playbooks/site.yml -e is_staging_deployment=true

# Deploy only changed services (detected automatically in CI)
ansible-playbook playbooks/site.yml -e changed_services=nightscout,homepage

# Install Ansible collections
ansible-galaxy collection install -r requirements.yml
```

## Deployment Workflows

**Standard Deployment** (`.github/workflows/deploy.yml`):
- Sequential deployment with Mitogen optimization
- Auto-detects changed services on push
- Supports manual triggers with custom limits/tags
- Runs in check mode on PRs

**Parallel Deployment** (`.github/workflows/deploy-parallel.yml`):
- Deploys to mljr and nuc simultaneously
- Each host in separate job for better visibility
- Faster for multi-host deployments
- Manual trigger only

Use parallel deployment when deploying to multiple hosts for maximum speed.

## Architecture

### Host Groups

```yaml
managed:
  rocky:       # Rocky Linux - full deployment (mljr=production, nuc=staging)
  unraid:      # Unraid NAS (nas) - limited management
proxy_only:    # Caddy config only, not SSH-reachable (pi, monitoring)
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
    port: 1337                    # Required for managed services (use 0 for no web UI)
    host: mljr                    # Must match inventory hostname
    caddy_auth: "basicauth"       # "basicauth", "authelia", or "keycloak" (deprecated) for SSO
    managed: false                # External service (proxy only, no docker-compose)
    skip_deploy: true             # Uses dedicated role instead of services role
    backup_critical: true         # Restore on fresh install
    requires_sysctl: "key=value"  # System tuning (e.g., vm.max_map_count=262144)
```

### Authentication

Three authentication methods are available via `caddy_auth`:

| Value | Description |
|-------|-------------|
| `basicauth` | Username/password from `CADDY_AUTH_USER` and `CADDY_AUTH_PASSWORD_HASH` |
| `authelia` | SSO via Authelia (current recommended method) |
| `keycloak` | SSO via Keycloak + oauth2-proxy (deprecated - replaced by Authelia) |

**Authelia SSO Architecture:**
```
User → Caddy → forward_auth → Authelia → User authenticated
```

Services using `caddy_auth: "authelia"`: goaccess, fail2ban-ui, sonarqube, dozzle

**Default credentials** (change after first login):
- Username: `admin`
- Password: `authelia`

### Post-Deploy Hooks

Services can have post-deploy scripts that run after docker-compose up:

```
services/<name>/hooks/post-deploy.sh
```

- Receives `SERVICE_NAME` and `SERVICE_PATH` environment variables
- `.env` file is sourced before execution
- Runs asynchronously with 10-minute timeout
- Used by Keycloak to auto-provision realm, client, and Google IdP

### Staging Environment

Staging is opt-in per service by creating a `dev/` subfolder:

- **Structure**: `services/<name>/dev/docker-compose.yml`
- **Auto-detection**: Services with `dev/` folder auto-deploy when `is_staging_deployment=true`
- **Explicit config**: Ports, tags, and all settings explicitly defined in `dev/docker-compose.yml`
- **Deployment**: All staging services deploy to `staging_host` (nuc) regardless of their `host` property
- **Domain**: `<service>.dev.mljr.eu` (e.g., nightscout.dev.mljr.eu)
- **Path**: `/opt/staging/<service>`
- **Caddy**: Proxies staging domains from mljr to nuc

Example `services/nightscout/dev/docker-compose.yml`:
```yaml
services:
  nightscout:
    image: nightscout/cgm-remote-monitor:latest
    ports:
      - "11337:1337"  # Staging port (production port + 10000)
    # ... rest of config
```

**Port Convention**: Staging services should use `production_port + 10000` for Caddy routing to work correctly.

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
4. **(Optional)** Create `services/<name>/hooks/post-deploy.sh` for post-deployment configuration
5. **(Optional) Create staging**: Create `services/<name>/dev/docker-compose.yml` with explicit staging config
6. Deploy: `ansible-playbook playbooks/site.yml --tags services`

## Ansible Tags

| Tag | Description |
|-----|-------------|
| base | System packages, Docker |
| caddy | Reverse proxy (always runs last) |
| services | Docker Compose services |
| beszel-agent | Beszel monitoring agent (all rocky hosts) |
| monitoring | Alias for beszel-agent |
| backup | Backup/restore configuration |
| security, fail2ban | Fail2ban (mljr only) |
| glance | Dashboard |
| mailcow | Mail server |
| keycloak | SSO Identity Provider (deprecated - replaced by authelia) |
| authelia | SSO Identity Provider (mljr only) |

## Key Services

### Authelia (SSO Identity Provider)
- **Domain**: auth.mljr.eu
- **Port**: 9091 (mljr)
- **Configuration**: File-based auth via `services/authelia/configuration.yml`
- **User database**: Local file at `services/authelia/users_database.yml`
- **Default credentials**: admin/authelia (change after first login)
- **Backend**: Redis for session storage, SQLite for persistent data
- **Integration**: Services use `caddy_auth: "authelia"` for SSO protection
- **Protected services**: goaccess, fail2ban-ui, sonarqube, dozzle

### Deprecated Services
- **Keycloak** (port 9732): Replaced by Authelia, kept for rollback capability
- **OAuth2-Proxy** (port 4180): No longer needed with Authelia's native forward_auth

### SonarQube (Code Quality)
- **Domain**: sonarqube.mljr.eu
- **Port**: 9000 (nuc)
- **System requirement**: `vm.max_map_count=262144` (auto-configured via `requires_sysctl`)
- **Default login**: admin/admin (change on first login)

## Triggering Deployment from External Repos

### Deploy a Specific Service (Recommended)

Pass the service name in `client_payload` to deploy only that service:

```yaml
- name: Trigger deployment for specific service
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{
        "event_type": "service-update",
        "client_payload": {
          "service": "my-service-name",
          "environment": "production"
        }
      }'
```

**Payload options:**
- `service` (required): Service name matching the service definition in `all.yml`
- `environment` (optional): `"production"`, `"staging"`, or omit for both

This is significantly faster than deploying all services since it only touches the specified service.

### Deploy All Services (Legacy)

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{"event_type": "service-update"}'
```

Without `client_payload.service`, repository dispatch deploys all services with `--tags services,caddy`.
