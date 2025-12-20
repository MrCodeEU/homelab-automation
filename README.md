# Homelab Automation

This repository contains everything needed to automatically deploy and manage a complete homelab setup across multiple devices using Ansible.

## ⚡ Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation

# 2. Install Ansible
# On Linux/WSL:
sudo apt update
sudo apt install ansible

# 3. Configure your inventory
# Edit ansible/inventory/hosts.yml to match your Tailscale hostnames
nano ansible/inventory/hosts.yml

# 4. Configure services
# Edit ansible/group_vars/all.yml to define your services and global settings
nano ansible/group_vars/all.yml

# 5. Deploy
cd ansible
ansible-playbook playbooks/site.yml
```

## 🏗️ Architecture

The automation supports deployment to three types of devices:
- **VPS**: Cloud-based Virtual Private Server (Rocky Linux)
- **Home Server**: Linux server running at home (Rocky Linux)
- **Unraid NAS**: Network Attached Storage running Unraid (Slackware-based)

All devices are connected via Tailscale VPN for secure SSH access.

**Ansible Migration:**
This project has been migrated from shell scripts to Ansible for better maintainability and idempotency.
- **Inventory**: `ansible/inventory/hosts.yml`
- **Configuration**: `ansible/group_vars/all.yml`
- **Playbooks**: `ansible/playbooks/`
- **Roles**: `ansible/roles/`

**OS-Specific Handling:**
- **Rocky/Debian**: Fully managed by Ansible roles (common, docker, caddy, glance).
- **Unraid**: Managed via a wrapper role that executes custom deployment scripts (`scripts/03-unraid-deploy.sh`).

## 🚀 Features

- **Automated Base Setup**: Installs essential packages (git, docker, curl, vim, htop, etc.) via `common` role.
- **Docker Installation**: Sets up Docker and Docker Compose via `docker` role.
- **Caddy Reverse Proxy**: Auto-configured HTTPS reverse proxy from YAML config via `caddy` role.
- **Glance Dashboard**: Beautiful self-hosted dashboard generated from config via `glance` role.

  - 🌤️ Weather widget
  - 📅 Calendar integration
  - 🕐 Multiple timezone clocks
  - 🐳 Docker container monitoring
  - 📊 Server stats (CPU, memory, disk)
  - 📰 RSS feeds (Hacker News, The Verge, TechCrunch)
  - 🔗 Service health monitoring
  - 📱 Reddit, Lobsters feeds
- **Nightscout CGM Monitoring**: Self-hosted continuous glucose monitoring with:
  - 🩺 Nightscout web interface with HTTPS
  - 🔄 Automatic LibreLink Up data sync
  - 💾 MongoDB database for CGM readings
  - 📊 Real-time glucose visualization
  - 🚨 Configurable alarms and notifications
  - 📱 Mobile-friendly interface
  - 🔐 Secure internal network for data connector
  - See [NIGHTSCOUT.md](docs/NIGHTSCOUT.md) for detailed setup
- **Uptime Kuma Ready**: Prepared for service monitoring integration (see [Uptime Kuma README](configs/uptime-kuma/README.md))
- **GitHub Workflows**: CI/CD pipeline with Tailscale SSH authentication
- **YAML-Driven Configuration**: Single `services.yml` file generates all configs
- **Tailscale Integration**: Secure VPN connectivity without SSH keys
- **🆕 Hooks-Based Deployment**: Flexible service deployment with optional hooks
  - **Pre-deploy hooks**: Run tasks before docker compose up (validation, preparation)
  - **Post-deploy hooks**: Initialize services after deployment (setup, data migration)
  - **Validation hooks**: Automated health checks and smoke tests
  - Self-contained services with hooks in their own directories
  - See [Service Development Guide](docs/SERVICE_DEVELOPMENT.md) for details

## 🔌 Service Deployment Hooks

Services support optional deployment hooks for customization:

### Hook Types

1. **pre-deploy.sh** - Runs before `docker compose up`
   - Use for: validation, preparation, dependency checks
   - Failure aborts deployment

2. **post-deploy.sh** - Runs after `docker compose up`
   - Use for: initialization, data migration, notifications
   - Failure logged as warning

3. **validate.sh** - Runs after post-deploy
   - Use for: health checks, smoke tests, integration tests
   - Failure logged as warning

### Example Service Structure

```
configs/my-service/
├── docker-compose.yml
├── config.yml
└── hooks/                  # Optional
    ├── pre-deploy.sh
    ├── post-deploy.sh
    └── validate.sh
```

### Creating a Service with Hooks

See [configs/example-service](configs/example-service/README.md) for a complete example with all hooks implemented.

**Quick example:**

```bash
# 1. Create service directory
mkdir -p configs/my-service/hooks

# 2. Add docker-compose.yml
# 3. (Optional) Add hooks
# 4. Add to services.yml
# 5. Deploy!
```

See the [Service Development Guide](docs/SERVICE_DEVELOPMENT.md) for detailed instructions.

## 📁 Repository Structure

```
homelab-automation/
├── .github/
│   ├── workflows/
│   │   ├── deploy-all.yml      # Deploy to all devices sequentially
│   │   ├── deploy-vps.yml      # Deploy VPS only
│   │   ├── deploy-homeserver.yml  # Deploy home server only
│   │   ├── deploy-unraid.yml   # Deploy Unraid only
│   │   └── README.md           # Workflow documentation
│   └── SECRETS_TEMPLATE.md     # GitHub Secrets setup guide
├── configs/
│   ├── caddy/
│   │   └── Caddyfile.example   # Example Caddy configuration
│   └── docker/
│       ├── portainer/          # Docker management UI
│       ├── watchtower/         # Auto-update containers
│       └── homepage/           # Application dashboard
├── scripts/
│   ├── deploy.sh               # Main deployment orchestration script
│   ├── deploy-single.sh        # Single device deployment helper
│   ├── generate-configs.sh     # Generate Caddy & Glance configs from YAML
│   ├── 01-base-setup.sh        # Base system setup (OS-aware)
│   ├── 02-docker-setup.sh      # Docker installation (OS-aware)
│   ├── 03-docker-compose-deploy.sh  # Docker Compose deployment
│   ├── 03-unraid-deploy.sh     # Unraid-specific Docker deployment
│   ├── 04-caddy-setup.sh       # Caddy setup and configuration (OS-aware)
│   ├── 05-glance-setup.sh      # Glance dashboard deployment
│   └── 06-nightscout-setup.sh  # Nightscout + LibreLink Up deployment
├── inventory.yml               # Device inventory with OS types
└── README.md
```

## 🔧 Setup

### Prerequisites

1. **Tailscale Account**: Set up at [tailscale.com](https://tailscale.com)
2. **SSH Access**: Ensure SSH access to all target devices
3. **SSH Key**: Generate an SSH key pair for authentication

### Configuration

1. **Clone the repository**:
   ```bash
   git clone https://github.com/MrCodeEU/homelab-automation.git
   cd homelab-automation
   ```

2. **Configure inventory.yml**:
   Edit `inventory.yml` and update with your actual Tailscale hostnames and OS types:
   ```yaml
   devices:
     vps:
       hostname: "your-vps.tailnet-xxx.ts.net"
       user: "root"
       os: "rocky"  # Rocky Linux
     homeserver:
       hostname: "your-homeserver.tailnet-xxx.ts.net"
       user: "root"
       os: "rocky"  # Rocky Linux
     unraid:
       hostname: "your-unraid.tailnet-xxx.ts.net"
       user: "root"
       os: "slackware"  # Unraid (Slackware-based)
   ```

3. **Customize Caddy Configuration**:
   - Copy `configs/caddy/Caddyfile.example` to `configs/caddy/Caddyfile`
   - Update with your actual domain names and services

4. **Add Docker Compose Services**:
   - Add your docker-compose.yml files to `configs/docker/`
   - Each service should be in its own subdirectory

### GitHub Secrets (for automated deployment)

Configure the following secrets in your GitHub repository (see [.github/SECRETS_TEMPLATE.md](.github/SECRETS_TEMPLATE.md) for details):

**Tailscale OAuth:**
- `TS_OAUTH_CLIENT_ID`: Tailscale OAuth client ID
- `TS_OAUTH_SECRET`: Tailscale OAuth secret (get from https://login.tailscale.com/admin/settings/oauth)

**Device Credentials:**
- `VPS_USER`: SSH username for VPS (usually `root`)
- `VPS_HOST`: Tailscale hostname for VPS (e.g., `vps.tailnet-xxx.ts.net`)
- `HOMESERVER_USER`: SSH username for home server
- `HOMESERVER_HOST`: Tailscale hostname for home server
- `UNRAID_USER`: SSH username for Unraid
- `UNRAID_HOST`: Tailscale hostname for Unraid NAS

**Note:** The new workflows use Tailscale SSH (no SSH keys needed!). See [.github/workflows/README.md](.github/workflows/README.md) for full setup instructions.

## 📦 Usage

### Manual Deployment

Make scripts executable:
```bash
chmod +x scripts/*.sh
```

Deploy to all devices:
```bash
./scripts/deploy.sh all all
```

Deploy to a specific device with OS specified:
```bash
# VPS (Rocky Linux) - all roles
./scripts/deploy-single.sh vps.tailnet-xxx.ts.net root rocky all

# Home server (Rocky Linux) - docker and caddy only
./scripts/deploy-single.sh homeserver.tailnet-xxx.ts.net root rocky docker,caddy

# Unraid NAS (Slackware) - base and docker (uses community templates)
./scripts/deploy-single.sh unraid.tailnet-xxx.ts.net root slackware docker
```

Or use auto-detection (not recommended for Unraid):
```bash
./scripts/deploy-single.sh vps.tailnet-xxx.ts.net root auto all
```

### Automated Deployment via GitHub Actions

**New modular workflows** - Deploy individually or all at once!

**Deploy all devices (sequential):**
1. Go to the **Actions** tab in your GitHub repository
2. Select **Deploy All Devices** workflow
3. Click **Run workflow**, choose roles
4. Deploys: VPS → Home Server → Unraid

**Deploy individual device (for testing):**
1. Select **Deploy VPS**, **Deploy Home Server**, or **Deploy Unraid**
2. Click **Run workflow**, choose roles
3. Test changes without affecting other devices

See [.github/workflows/README.md](.github/workflows/README.md) for detailed workflow documentation.

## 🛠️ Available Scripts

| Script | Description |
|--------|-------------|
| `generate-configs.sh` | Generates Caddyfile and Glance config from services.yml |
| `01-base-setup.sh` | Installs essential packages and utilities (OS-aware) |
| `02-docker-setup.sh` | Installs Docker and Docker Compose (OS-aware) |
| `03-docker-compose-deploy.sh` | Deploys Docker Compose stacks (Rocky Linux) |
| `03-unraid-deploy.sh` | Deploys Docker containers on Unraid (Community Apps style) |
| `04-caddy-setup.sh` | Installs and configures Caddy reverse proxy (OS-aware) |
| `05-glance-setup.sh` | Deploys Glance dashboard with auto-generated config |
| `06-nightscout-setup.sh` | Deploys Nightscout CGM monitor + LibreLink Up connector |
| `deploy.sh` | Main orchestration script that runs all others |
| `deploy-single.sh` | Single device deployment helper with OS parameter |

## 🐳 Included Docker Services

**Core Services (Rocky Linux):**
- **Caddy**: Reverse proxy with automatic HTTPS (ports 80, 443)
- **Glance**: Self-hosted dashboard (port 8080)
- **Nightscout** *(optional)*: CGM monitoring (port 1337)
  - MongoDB database
  - LibreLink Up connector
  - See [docs/NIGHTSCOUT.md](docs/NIGHTSCOUT.md) for setup

**Additional Services (via docker-compose):**
- **Portainer**: Web-based Docker management UI (port 9000)
- **Watchtower**: Automatic container update service
- **Homepage**: Application dashboard (port 3000)

**For Unraid (via native Docker):**
- **Portainer**: Docker management UI with Unraid appdata storage
- **Watchtower**: Auto-updates for Unraid containers
- **Homepage**: Dashboard with proper Unraid paths

**Add more services:**
- Rocky Linux: Create docker-compose.yml files in `configs/docker/` or add to `services.yml`
- Unraid: Use Community Applications UI or modify `03-unraid-deploy.sh`

## 🔒 Security Notes

- All SSH connections use Tailscale VPN for encryption
- SSH host key checking is disabled in scripts (configure as needed)
- Caddy automatically handles HTTPS with Let's Encrypt
- Keep your SSH private keys and Tailscale credentials secure
- Review and customize firewall rules for your environment

## 🤝 Contributing

Feel free to submit issues and enhancement requests!

## 📝 License

This project is open source and available under the MIT License.
