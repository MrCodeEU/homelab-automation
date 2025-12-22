# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a homelab automation repository that deploys and manages self-hosted services across multiple devices via **Ansible** over Tailscale VPN. The system supports Rocky Linux servers, Debian/Raspberry Pi, and Unraid NAS, with automated deployment through GitHub Actions.

## Key Architecture

### Ansible-Based Deployment

The deployment is managed entirely through Ansible:

- **Inventory**: `ansible/inventory/hosts.yml` - Defines all target hosts grouped by OS
- **Configuration**: `ansible/inventory/group_vars/all.yml` - Central service definitions and secrets
- **Playbooks**: `ansible/playbooks/site.yml` - Main orchestration playbook
- **Roles**: `ansible/roles/` - Modular task collections (common, docker, caddy, glance, services, unraid)

### Host Groups

```yaml
all:
  children:
    rocky:      # Rocky Linux hosts (mljr, homeserver)
    debian:     # Debian hosts (pi)
    unraid:     # Unraid NAS (nas)
    docker_hosts:  # Alias for rocky + debian
```

### Service Configuration

Services are defined in `ansible/inventory/group_vars/all.yml`:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: ["nightscout.mljr.eu", "ns.mljr.eu"]
    port: 1337
    host: mljr
    description: "CGM Monitor"
    icon: "mdi:diabetes"
```

Key fields:
- **enabled**: If false, service is completely skipped
- **managed**: If false, Caddy still configured but no deployment (external services)
- **host**: Must match a host name in inventory (e.g., `mljr`, `pi`)
- **domain**: String or array (all domains get Caddy reverse proxy)
- **caddy_auth**: Set to `"basicauth"` for password protection

### Ansible Roles

| Role | Purpose | Hosts |
|------|---------|-------|
| `common` | Install base packages (git, curl, vim, etc.) | rocky, debian |
| `docker` | Install Docker and Docker Compose | rocky, debian |
| `caddy` | Install Caddy, generate Caddyfile from templates | rocky |
| `glance` | Deploy Glance dashboard container | mljr |
| `services` | Deploy Docker Compose services from `configs/` | rocky, debian |
| `unraid` | Run Unraid-specific deployment script | unraid |

### Secret Management

Secrets are injected via environment variables and Ansible lookups:

```yaml
# In group_vars/all.yml
nightscout_api_secret: "{{ lookup('env', 'NIGHTSCOUT_API_SECRET') }}"
```

GitHub Actions sets these as environment variables before running Ansible.

## Common Development Commands

### Local Deployment

```bash
# Deploy everything to all hosts
cd ansible && ansible-playbook playbooks/site.yml

# Deploy to specific host
cd ansible && ansible-playbook playbooks/site.yml --limit mljr

# Deploy specific roles
cd ansible && ansible-playbook playbooks/site.yml --tags caddy,services

# Dry run (check mode)
cd ansible && ansible-playbook playbooks/site.yml --check

# Verbose output
cd ansible && ansible-playbook playbooks/site.yml -vvv
```

### Testing

```bash
# Test inventory parsing
cd ansible && ansible-inventory --list

# Test connectivity
cd ansible && ansible all -m ping

# Run ad-hoc commands
cd ansible && ansible mljr -m shell -a "docker ps"
```

## Adding a New Service

1. **Add to services list** in `ansible/inventory/group_vars/all.yml`:
```yaml
services:
  - name: myservice
    enabled: true
    domain: "myservice.mljr.eu"
    port: 8080
    host: mljr
    description: "My Service"
    icon: "mdi:icon-name"
```

2. **Create service config** at `configs/myservice/docker-compose.yml`

3. **Add secrets** (if needed):
   - Add to `group_vars/all.yml` with env lookup
   - Add to GitHub Secrets
   - Reference in `ansible/roles/services/templates/env.j2`

4. **Deploy**:
```bash
cd ansible && ansible-playbook playbooks/site.yml --limit mljr --tags services
```

## File Structure

```
ansible/
├── ansible.cfg              # Ansible configuration
├── requirements.yml         # Galaxy collection dependencies
├── inventory/
│   ├── hosts.yml            # Host definitions
│   └── group_vars/
│       └── all.yml          # Services, secrets, global vars
├── playbooks/
│   └── site.yml             # Main playbook
└── roles/
    ├── common/tasks/        # Base package installation
    ├── docker/tasks/        # Docker installation
    ├── caddy/
    │   ├── tasks/           # Caddy installation
    │   ├── templates/       # Caddyfile.j2, index.html.j2
    │   └── handlers/        # Reload Caddy
    ├── glance/
    │   ├── tasks/           # Glance container deployment
    │   ├── templates/       # glance.yml.j2
    │   └── handlers/        # Restart Glance
    ├── services/
    │   ├── tasks/           # Docker Compose deployment
    │   └── templates/       # env.j2 (secrets template)
    └── unraid/tasks/        # Unraid script wrapper

configs/
├── {service}/               # Service-specific configs
│   ├── docker-compose.yml
│   └── hooks/               # Optional deployment hooks
│       ├── pre-deploy.sh
│       ├── post-deploy.sh
│       └── validate.sh

scripts/
├── common.sh                # Shared shell functions
└── 03-unraid-deploy.sh      # Unraid deployment (called by Ansible)

.github/workflows/
└── ansible-deploy.yml       # GitHub Actions workflow
```

## Jinja2 Templates

### Caddyfile Generation (`ansible/roles/caddy/templates/Caddyfile.j2`)

The Caddyfile is generated from the services list:
- Iterates over enabled services
- Creates reverse proxy entries for each domain
- Supports basicauth via `caddy_auth` field
- Resolves host to Tailscale hostname via `hostvars`

### Glance Dashboard (`ansible/roles/glance/templates/glance.yml.j2`)

Generated dashboard config with:
- Weather widget (location from vars)
- Service health monitors (from services list)
- Docker container status
- RSS feeds

## GitHub Actions Workflow

The workflow (`ansible-deploy.yml`):
1. Checks out repository
2. Sets up Tailscale VPN
3. Installs Ansible (cached)
4. Installs Galaxy collections
5. Runs playbook with specified limit/tags

Secrets are passed as environment variables.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Host unreachable | Check Tailscale status, verify hostname in inventory |
| Permission denied | Verify `ansible_user` and sudo/become settings |
| Service not deployed | Check `enabled: true` and `host` matches inventory |
| Caddy config wrong | Check template syntax, run with `--tags caddy -vvv` |
| Docker pull slow | Pre-pull images or use local registry |
| Module not found | Run `ansible-galaxy collection install -r requirements.yml` |

## Performance Optimizations

The Ansible configuration includes several optimizations to improve deployment speed:

### SSH Optimizations (`ansible.cfg`)
- **Pipelining**: `pipelining = True` - Reduces SSH connections by sending multiple commands
- **Control Persist**: `ControlPersist=60s` - Keeps SSH connections open for reuse
- **Parallel Forks**: `forks = 10` - Run tasks on multiple hosts simultaneously

### Fact Caching
- **Smart Gathering**: `gathering = smart` - Only gather facts when needed
- **JSON File Cache**: Facts cached to `/tmp/ansible_facts_cache` for 24 hours
- **Minimal Subset**: Only gather `min`, `os_family`, `distribution`, `service_mgr`

### Playbook Optimizations
- **Free Strategy**: Services play uses `strategy: free` for parallel task execution
- **Conditional Execution**: Skip Docker installation if already present
- **Async Tasks**: Docker Compose deployments run in parallel with `async`
- **Cache Valid Time**: APT cache only updated if older than 1 hour

### Expected Performance
- **First Run**: ~5-8 minutes (full installation)
- **Subsequent Runs**: ~2-3 minutes (mostly config updates)
- **Services Only**: ~1-2 minutes (just Docker Compose)

### Tips for Faster Deployments
1. Use `--tags` to run only needed roles
2. Use `--limit` to target specific hosts
3. Pre-pull Docker images on hosts
4. Run `--tags services` for config-only updates

