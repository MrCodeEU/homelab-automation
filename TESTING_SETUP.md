# Minimal Testing Setup - Rocky Linux Only

This is a streamlined version of the homelab automation focused on Rocky Linux systems only, perfect for initial testing.

## Assumptions

- **Tailscale is pre-installed and connected** on all devices
- All systems run **Rocky Linux**
- SSH access is available via Tailscale

## What This Deploys

### Base Setup (`base` role)
- Essential packages: git, curl, wget, vim, htop, etc.
- System updates

### Docker Setup (`docker` role)
- Docker Engine
- Docker Compose plugin

### Caddy Setup (`caddy` role)
- Caddy reverse proxy (as Docker container)
- Auto-generated Caddyfile from `services.yml`

## Quick Start

### 1. Configure Services

Edit `configs/services.yml` to define your services:

```yaml
global:
  domain: "yourdomain.com"
  email: "you@yourdomain.com"

services:
  - name: portainer
    enabled: true
    domain: "portainer.yourdomain.com"
    port: 9000
```

### 2. Set GitHub Secrets

Required secrets (6 total):
- `TS_OAUTH_CLIENT_ID` - Tailscale OAuth client ID
- `TS_OAUTH_SECRET` - Tailscale OAuth secret  
- `VPS_USER` - SSH user for VPS (usually `root`)
- `VPS_HOST` - Tailscale hostname for VPS
- `HOMESERVER_USER` - SSH user for home server
- `HOMESERVER_HOST` - Tailscale hostname for home server

### 3. Deploy

**Test VPS only:**
1. Go to Actions → "Deploy VPS"
2. Select role: `base`
3. Run workflow

**Deploy everything:**
1. Go to Actions → "Deploy All Devices"
2. Select role: `all`
3. Run workflow

## File Structure

```
homelab-automation/
├── .github/workflows/
│   ├── deploy-all.yml           # Deploy both devices
│   ├── deploy-vps.yml          # Deploy VPS only
│   └── deploy-homeserver.yml   # Deploy home server only
├── configs/
│   ├── services.yml            # Service definitions (NEW!)
│   └── caddy/
│       └── Caddyfile.example   # Example Caddyfile
├── scripts/
│   ├── 01-base-setup.sh        # Install packages
│   ├── 02-docker-setup.sh      # Install Docker
│   ├── 03-docker-compose-deploy.sh  # Deploy Caddy container
│   ├── 04-caddy-setup.sh       # Set up Caddy
│   └── generate-configs.sh     # Generate Caddyfile from YAML (NEW!)
└── inventory.yml               # Device inventory
```

## How It Works

1. **Copy files** to remote host via Tailscale SSH
2. **Run base setup** - Install essential packages
3. **Run Docker setup** - Install Docker
4. **Generate configs** - Create Caddyfile from services.yml
5. **Deploy Caddy** - Start Caddy container with generated config

## Configuration Generation

The `generate-configs.sh` script reads `services.yml` and automatically creates:
- ✅ Caddyfile with reverse proxy rules
- 🔮 Docker compose (coming soon)
- 🔮 Dashboard configs (coming soon)

## Deployment Roles

- `base` - System packages only
- `docker` - Docker installation only
- `caddy` - Caddy + config generation only
- `all` - Everything

## Testing Workflow

1. Start with `base` role on VPS
2. Then add `docker` role
3. Finally add `caddy` role
4. Once VPS works, deploy to home server
5. Finally use "Deploy All" for synchronized deployments

## Troubleshooting

### Tailscale not connected
```bash
# On each device
tailscale status
```

### Docker not starting
```bash
systemctl status docker
systemctl start docker
```

### Caddy not accessible
```bash
cd /opt/caddy
docker compose ps
docker compose logs
```

### Regenerate Caddyfile
Edit `configs/services.yml`, then re-run with `caddy` role selected.

## What Was Removed

- ❌ Unraid/Slackware support
- ❌ Ubuntu/Debian support
- ❌ OS detection logic
- ❌ Multiple docker services
- ❌ Complex configuration

## Future Enhancements

- Docker compose generation from services.yml
- Dashboard (Glances) configuration
- Monitoring setup
- Backup scripts

## Notes

- All paths are simplified
- No SSH key management (uses Tailscale)
- Minimal dependencies
- Easy to understand and modify
- Perfect for learning and testing
