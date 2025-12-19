# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a homelab automation repository that deploys and manages self-hosted services across multiple devices via SSH over Tailscale VPN. The system supports Rocky Linux servers and Unraid NAS, with automated deployment through GitHub Actions.

## Key Architecture

### YAML-Driven Configuration System

The entire system is driven by two main YAML files:

- **`configs/services.yml`**: Central service registry defining all services, their domains, ports, hosts, and deployment settings. This file is parsed by `scripts/generate-configs.sh` to automatically generate:
  - Caddyfile (reverse proxy configuration)
  - Glance dashboard config
  - Default index.html with service links

- **`inventory.yml`**: Device inventory with Tailscale hostnames, fallback IPs, OS types, and assigned roles

### Multi-Host Service Resolution

The `generate-configs.sh` script cross-references `services.yml` and `inventory.yml` to resolve service locations:
- If a service specifies `host: mljr`, the script looks up `mljr` in inventory to get the Tailscale hostname
- It generates reverse proxy rules with both Tailscale hostname and fallback IPs
- For local services (no host or `host: localhost`), it uses `127.0.0.1`
- This enables services to run on different physical machines (VPS, home server, Raspberry Pi, NAS)

### Service Deployment Lifecycle

Services follow this lifecycle managed by `scripts/deploy-service.sh`:

1. **Check service status** from services.yml (`enabled`, `managed`, `skip_deploy`)
2. **Custom setup script** (if exists): Execute `scripts/setup-{service}.sh` for complex services
3. **Standard deployment** (if no custom script): Deploy from `configs/{service}/docker-compose.yml`
4. **Secret injection**: Run `scripts/inject-secrets.sh` to replace placeholders like `__NIGHTSCOUT_API_SECRET__`
5. **State tracking**: Record deployed services in `/opt/homelab-state/managed_services.txt`
6. **Cleanup**: Remove services that were deleted from services.yml

### Deployment Roles

Scripts are organized by role (executed in order):

- **base** (`01-base-setup.sh`): Install system packages (git, docker, vim, htop, etc.)
- **docker** (`02-docker-setup.sh`): Install Docker/Docker Compose, then call `03-docker-compose-deploy.sh` or `03-unraid-deploy.sh`
- **caddy** (`generate-configs.sh` → service deployment): Generate configs from YAML and deploy all services

### OS Awareness

All setup scripts accept an OS parameter (rocky, slackware, ubuntu, debian, auto):
- Rocky Linux: Uses `dnf`/`yum`, systemd, standard paths
- Unraid (Slackware): Uses Docker natively, custom deployment in `03-unraid-deploy.sh`
- The `deploy.sh` script auto-detects OS from device descriptions in inventory.yml

### Secret Management

Secrets are injected via `scripts/inject-secrets.sh`:
- Reads from `secrets.env` (git-ignored, copied during deployment)
- Replaces `__PLACEHOLDER__` patterns in config files with actual values
- Service-specific injection scripts exist (e.g., `scripts/inject-caddy-secrets.sh`)

## Common Development Commands

### Local Testing

```bash
# Deploy to a single device with OS specified
./scripts/deploy-single.sh <hostname> <user> <os> <roles>

# Example: Deploy everything to VPS
./scripts/deploy-single.sh mljr.tail33930.ts.net root rocky all

# Example: Deploy only Caddy/services to home server
./scripts/deploy-single.sh nuc.tail33930.ts.net root rocky caddy
```

### Configuration Generation

```bash
# Generate Caddyfile and Glance config from services.yml
./scripts/generate-configs.sh \
  /tmp/homelab-deploy/configs/services.yml \
  /opt/caddy \
  /opt/glance \
  /tmp/homelab-deploy/inventory.yml
```

### Working with Services

When adding a new service:

1. **Simple service**: Add to `configs/services.yml` and create `configs/{service}/docker-compose.yml`
2. **Complex service**: Add to `configs/services.yml`, create setup script `scripts/setup-{service}.sh`, and service configs
3. Set `managed: false` if deployed by custom script (like mailcow)
4. Set `skip_deploy: true` to exclude from auto-deployment but include in Caddy/Glance

### GitHub Actions Deployment

The CI/CD uses modular workflows:
- `deploy-all.yml`: Deploys to all devices sequentially
- `deploy-vps.yml`, `deploy-homeserver.yml`: Individual device workflows
- All use Tailscale SSH (no SSH keys needed)
- Secrets are injected from GitHub Secrets into `secrets.env`

## Important Patterns

### Adding a New Service

1. Add service definition to `configs/services.yml`:
```yaml
services:
  - name: myservice
    enabled: true
    domain: "myservice.mljr.eu"
    port: 8080
    host: mljr  # or pi, nas, homeserver
    description: "My Service"
    icon: "mdi:icon-name"
```

2. Create `configs/myservice/docker-compose.yml` OR `scripts/setup-myservice.sh`

3. If secrets needed, add placeholders to config and update `scripts/inject-secrets.sh`

4. Deploy with `./scripts/deploy-single.sh <host> root rocky caddy`

### Service Fields in services.yml

- **enabled**: If false, service is completely skipped
- **managed**: If false, Caddy/Glance still configured but no deployment (for external services)
- **skip_deploy**: If true, no deployment but Caddy/Glance still configured
- **domain**: Can be a string or array (first used for links, all used in Caddy)
- **host**: Reference to device in inventory.yml (resolved to Tailscale hostname + fallbacks)
- **upstream**: If set, overrides `host:port` logic
- **caddy_auth**: Set to "basicauth" for basic authentication
- **caddy_directives**: Custom Caddy config block (indented automatically)

### Uptime Kuma Provisioning

The `scripts/provision-kuma.py` script automatically creates/updates monitors from `services.yml`:
- Reads enabled services with domains
- Creates HTTP monitors in Uptime Kuma
- Requires `KUMA_USERNAME` and `KUMA_PASSWORD` environment variables
- Uses the `uptime-kuma-api` Python package (installed via `pip install uptime-kuma-api-v2`)

### Post-Deployment Fixes

The `scripts/post-deploy-fixes.sh` script contains idempotent environment-specific fixes:
- Network adjustments (e.g., `fix-nightscout-network.sh`)
- Port conflict resolution (e.g., `fix-mailcow-ports.sh`)
- Run automatically after service deployment

## File Structure

```
scripts/
├── deploy.sh                      # Main orchestrator (reads inventory.yml)
├── deploy-single.sh               # Single device deployment helper
├── deploy-service.sh              # Generic service deployment logic
├── generate-configs.sh            # YAML → Caddyfile/Glance/index.html
├── 01-base-setup.sh               # OS-aware base packages
├── 02-docker-setup.sh             # OS-aware Docker installation
├── 03-docker-compose-deploy.sh    # Service deployment + cleanup
├── 03-unraid-deploy.sh            # Unraid-specific Docker deployment
├── setup-{service}.sh             # Custom setup scripts for complex services
├── inject-secrets.sh              # Secret placeholder replacement
├── post-deploy-fixes.sh           # Idempotent environment fixes
└── provision-kuma.py              # Uptime Kuma monitor automation

configs/
├── services.yml                   # Central service registry
├── {service}/                     # Service-specific configs
│   ├── docker-compose.yml
│   ├── .env.template
│   └── config files...

inventory.yml                      # Device inventory
```

## Testing

When testing configuration changes:
1. Modify `configs/services.yml`
2. Run `./scripts/generate-configs.sh configs/services.yml /tmp/test-caddy /tmp/test-glance inventory.yml`
3. Inspect generated `/tmp/test-caddy/Caddyfile` and `/tmp/test-glance/glance.yml`
4. Deploy with `deploy-single.sh` to test device

## Troubleshooting

- **Service not accessible**: Check if enabled in services.yml, verify Caddy config generated, ensure port exposed in docker-compose
- **Wrong host resolution**: Verify `host` field matches inventory.yml device name, check Tailscale connectivity
- **Secrets not injected**: Ensure `secrets.env` exists and contains required variables, check placeholder format (`__VAR__`)
- **Deployment fails**: Check OS parameter matches actual OS, verify scripts are executable, review logs from specific role script
