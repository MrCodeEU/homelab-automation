# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a homelab automation repository that deploys and manages self-hosted services across multiple devices via **Ansible** over Tailscale VPN. The system supports Rocky Linux servers and Unraid NAS, with automated deployment through GitHub Actions. Additional hosts are configured as proxy-only targets for Caddy reverse proxy.

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
    rocky:      # Rocky Linux hosts (mljr)
    unraid:     # Unraid NAS (nas)
    proxy_only: # Proxy-only hosts (pi, homeserver, monitoring)
    docker_hosts:  # Alias for rocky + unraid
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
- **skip_deploy**: If true, service excluded from generic services role (use dedicated role instead)

**Note**: Services like `glance` and `fail2ban-ui` use dedicated roles and are excluded from generic deployment via `services_excluded_from_generic_deployment` list.

### Ansible Roles

| Role | Purpose | Hosts |
|------|---------|-------|
| `common` | Install base packages (git, curl, vim, etc.) | rocky |
| `docker` | Install Docker and Docker Compose | rocky |
| `caddy` | Install Caddy, generate Caddyfile from templates | rocky |
| `fail2ban` | Security monitoring with intrusion detection | rocky |
| `glance` | Deploy Glance dashboard container | mljr |
| `services` | Deploy Docker Compose services from `configs/` | rocky |
| `unraid` | Run Unraid-specific deployment script | unraid |

#### fail2ban Role (Security)
- Monitors SSH, Caddy basicauth failures, and malicious bot requests
- Bans IPs after repeated violations (5 attempts in 10 minutes)
- Sends notifications via ntfy integration
- Deploys fail2ban-ui for web-based monitoring
- Custom filters for Caddy JSON log parsing

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

### Using Makefile Shortcuts

The repository includes a Makefile with convenient commands:

```bash
# Prerequisite checks
make check              # Verify Ansible installation and inventory

# Setup
make install            # Install Ansible Galaxy collections
make lint              # Syntax check all playbooks

# Testing
make ping              # Test connectivity to all hosts

# Deployment
make deploy            # Deploy to all hosts
make deploy-vps        # Deploy to VPS (mljr) only
make deploy-home       # Deploy to home server only
make deploy-pi         # Deploy to Raspberry Pi only
make deploy-caddy      # Deploy only Caddy configuration
make deploy-services   # Deploy only services

# Utilities
make dry-run           # Run in check mode (no changes)
make verbose           # Deploy with verbose output (-vvv)
make clean             # Remove temporary files
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
│   └── hooks/               # Optional deployment hooks (not auto-executed)
│       ├── pre-deploy.sh    # Example: validation, preparation
│       ├── post-deploy.sh   # Example: initialization, setup
│       └── validate.sh      # Example: health checks
│   └── provision-*.py       # Custom provisioning scripts (e.g., kuma)

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

### Workflow Inputs
- **limit**: Target hosts (all, mljr, homeserver, unraid)
- **tags**: Roles to run (all, base, docker, caddy, services, security, fail2ban)
- **build_librelink**: Trigger LibreLink connector image build before deployment

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

