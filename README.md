# Homelab Automation

This repository contains everything needed to automatically deploy and manage a complete homelab setup across multiple devices using SSH over Tailscale VPN.

## 🏗️ Architecture

The automation supports deployment to three types of devices:
- **VPS**: Cloud-based Virtual Private Server
- **Home Server**: Linux server running at home
- **Unraid NAS**: Network Attached Storage running Unraid

All devices are connected via Tailscale VPN for secure SSH access.

## 🚀 Features

- **Automated Base Setup**: Installs essential packages (git, docker, curl, vim, htop, etc.)
- **Docker Installation**: Sets up Docker and Docker Compose on all devices
- **Docker Stack Deployment**: Automatically deploys containerized services
- **Caddy Configuration**: Deploys and configures Caddy reverse proxy
- **GitHub Workflows**: CI/CD pipeline for automated deployments
- **Tailscale Integration**: Secure VPN connectivity for remote management

## 📁 Repository Structure

```
homelab-automation/
├── .github/
│   └── workflows/
│       └── deploy.yml          # GitHub Actions workflow for deployment
├── configs/
│   ├── caddy/
│   │   └── Caddyfile.example   # Example Caddy configuration
│   └── docker/
│       ├── portainer/          # Docker management UI
│       ├── watchtower/         # Auto-update containers
│       └── homepage/           # Application dashboard
├── scripts/
│   ├── deploy.sh               # Main deployment orchestration script
│   ├── 01-base-setup.sh        # Base system setup
│   ├── 02-docker-setup.sh      # Docker installation
│   ├── 03-docker-compose-deploy.sh  # Docker Compose deployment
│   └── 04-caddy-setup.sh       # Caddy setup and configuration
├── inventory.yml               # Device inventory and configuration
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
   Edit `inventory.yml` and update with your actual Tailscale hostnames:
   ```yaml
   devices:
     vps:
       hostname: "your-vps.tailnet-xxx.ts.net"
       user: "root"
     homeserver:
       hostname: "your-homeserver.tailnet-xxx.ts.net"
       user: "root"
     unraid:
       hostname: "your-unraid.tailnet-xxx.ts.net"
       user: "root"
   ```

3. **Customize Caddy Configuration**:
   - Copy `configs/caddy/Caddyfile.example` to `configs/caddy/Caddyfile`
   - Update with your actual domain names and services

4. **Add Docker Compose Services**:
   - Add your docker-compose.yml files to `configs/docker/`
   - Each service should be in its own subdirectory

### GitHub Secrets (for automated deployment)

Configure the following secrets in your GitHub repository:

- `SSH_PRIVATE_KEY`: Your SSH private key
- `TS_OAUTH_CLIENT_ID`: Tailscale OAuth client ID
- `TS_OAUTH_SECRET`: Tailscale OAuth secret
- `VPS_HOST`: Tailscale hostname for VPS
- `HOMESERVER_HOST`: Tailscale hostname for home server
- `UNRAID_HOST`: Tailscale hostname for Unraid NAS

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

Deploy to a specific device:
```bash
./scripts/deploy.sh vps all
./scripts/deploy.sh homeserver docker,caddy
./scripts/deploy.sh unraid base,docker
```

### Automated Deployment via GitHub Actions

1. Go to the **Actions** tab in your GitHub repository
2. Select **Deploy Homelab** workflow
3. Click **Run workflow**
4. Choose target device and roles
5. Click **Run workflow** to start deployment

## 🛠️ Available Scripts

| Script | Description |
|--------|-------------|
| `01-base-setup.sh` | Installs essential packages and utilities |
| `02-docker-setup.sh` | Installs Docker and Docker Compose |
| `03-docker-compose-deploy.sh` | Deploys all Docker Compose stacks |
| `04-caddy-setup.sh` | Installs and configures Caddy |
| `deploy.sh` | Main orchestration script that runs all others |

## 🐳 Included Docker Services

- **Portainer**: Web-based Docker management UI (port 9000)
- **Watchtower**: Automatic container update service
- **Homepage**: Application dashboard (port 3000)

Add more services by creating docker-compose.yml files in `configs/docker/`.

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
