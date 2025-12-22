# Homelab Automation

Ansible-based automation for deploying and managing self-hosted services across multiple devices over Tailscale VPN.

## ⚡ Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation

# 2. Install Ansible
sudo apt update && sudo apt install ansible   # Debian/Ubuntu
# or
brew install ansible                           # macOS

# 3. Install Ansible collections
cd ansible && ansible-galaxy collection install -r requirements.yml

# 4. Configure inventory
# Edit ansible/inventory/hosts.yml with your Tailscale hostnames
nano ansible/inventory/hosts.yml

# 5. Configure services
# Edit ansible/inventory/group_vars/all.yml
nano ansible/inventory/group_vars/all.yml

# 6. Deploy
ansible-playbook playbooks/site.yml
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ansible-deploy.yml                                  │   │
│  │  - Sets up Tailscale VPN                            │   │
│  │  - Runs ansible-playbook                            │   │
│  └─────────────────────────────────────────────────────┘   │
└────────────────────────┬────────────────────────────────────┘
                         │ Tailscale VPN
         ┌───────────────┼───────────────┬──────────────────┐
         ▼               ▼               ▼                  ▼
    ┌─────────┐    ┌─────────┐    ┌─────────┐       ┌─────────┐
    │  mljr   │    │  nuc    │    │   pi    │       │   nas   │
    │  (VPS)  │    │ (Home)  │    │  (RPi)  │       │(Unraid) │
    │  Rocky  │    │  Rocky  │    │ Debian  │       │Slackware│
    └─────────┘    └─────────┘    └─────────┘       └─────────┘
```

### Supported Platforms

| Host | OS | Roles |
|------|----|----|
| VPS (mljr) | Rocky Linux | common, docker, caddy, glance, services |
| Home Server | Rocky Linux | common, docker, caddy, services |
| Raspberry Pi | Debian | common, docker, services |
| NAS | Unraid (Slackware) | unraid (custom script) |

## 🚀 Features

- **🔧 Automated Base Setup** - Installs essential packages via `common` role
- **🐳 Docker Management** - Installs Docker/Compose via `docker` role
- **🔒 Caddy Reverse Proxy** - Auto-configured HTTPS from Jinja2 templates
- **📊 Glance Dashboard** - Beautiful dashboard with weather, feeds, monitoring
- **🔌 Service Deployment** - Docker Compose services from `configs/` directory
- **🔐 Secret Management** - Secrets injected via environment variables
- **🌐 Tailscale VPN** - Secure deployment without exposing SSH
- **⚡ GitHub Actions CI/CD** - One-click deployment via workflow dispatch

## 📁 Repository Structure

```
homelab-automation/
├── ansible/
│   ├── ansible.cfg                 # Ansible configuration
│   ├── requirements.yml            # Galaxy collection dependencies
│   ├── inventory/
│   │   ├── hosts.yml               # Host definitions
│   │   └── group_vars/
│   │       └── all.yml             # Services, secrets, global vars
│   ├── playbooks/
│   │   └── site.yml                # Main orchestration playbook
│   └── roles/
│       ├── common/                 # Base package installation
│       ├── docker/                 # Docker installation
│       ├── caddy/                  # Caddy reverse proxy
│       ├── glance/                 # Glance dashboard
│       ├── services/               # Docker Compose deployment
│       └── unraid/                 # Unraid-specific tasks
├── configs/
│   ├── nightscout/                 # Service configurations
│   ├── kuma/
│   ├── ntfy/
│   └── ...
├── scripts/
│   ├── common.sh                   # Shared shell functions
│   └── 03-unraid-deploy.sh         # Unraid deployment script
└── .github/
    └── workflows/
        └── ansible-deploy.yml      # GitHub Actions workflow
```

## 🔧 Configuration

### Inventory (`ansible/inventory/hosts.yml`)

```yaml
all:
  children:
    rocky:
      hosts:
        mljr:
          ansible_host: mljr.tail33930.ts.net
          ansible_user: root
        homeserver:
          ansible_host: nuc.tail33930.ts.net
          ansible_user: root
    debian:
      hosts:
        pi:
          ansible_host: pi.tail33930.ts.net
          ansible_user: pi
    unraid:
      hosts:
        nas:
          ansible_host: nas.tail33930.ts.net
          ansible_user: root
```

### Services (`ansible/inventory/group_vars/all.yml`)

```yaml
services:
  - name: nightscout
    enabled: true
    domain: ["nightscout.mljr.eu", "ns.mljr.eu"]
    port: 1337
    host: mljr
    description: "CGM Monitor"
    icon: "mdi:diabetes"

  - name: homeassistant
    enabled: true
    managed: false          # External service, Caddy only
    domain: "home.mljr.eu"
    port: 8123
    host: pi

  - name: goaccess
    enabled: true
    domain: "logs.mljr.eu"
    port: 7890
    host: mljr
    caddy_auth: "basicauth" # Password protected
```

### Service Fields

| Field | Description |
|-------|-------------|
| `enabled` | If false, service is completely skipped |
| `managed` | If false, Caddy configured but no deployment |
| `host` | Must match inventory host name |
| `domain` | String or array of domains |
| `port` | Container port for reverse proxy |
| `caddy_auth` | Set to `"basicauth"` for password protection |

## 📦 Usage

### Deploy Everything

```bash
cd ansible
ansible-playbook playbooks/site.yml
```

### Deploy to Specific Host

```bash
ansible-playbook playbooks/site.yml --limit mljr
```

### Deploy Specific Roles

```bash
# Only Caddy configuration
ansible-playbook playbooks/site.yml --tags caddy

# Only services
ansible-playbook playbooks/site.yml --tags services

# Multiple tags
ansible-playbook playbooks/site.yml --tags "docker,services"
```

### Dry Run

```bash
ansible-playbook playbooks/site.yml --check
```

### Verbose Output

```bash
ansible-playbook playbooks/site.yml -vvv
```

## 🌐 GitHub Actions Deployment

1. Go to **Actions** tab in your repository
2. Select **Ansible Deploy** workflow
3. Click **Run workflow**
4. Choose:
   - **limit**: Target hosts (`all`, `mljr`, `homeserver`, `unraid`)
   - **tags**: Roles to run (`all`, `base`, `docker`, `caddy`, `services`)

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |
| `NIGHTSCOUT_API_SECRET` | Nightscout API secret |
| `LINK_UP_USERNAME` | LibreLink Up username |
| `LINK_UP_PASSWORD` | LibreLink Up password |
| `CADDY_AUTH_PASSWORD_HASH` | Bcrypt hash for basicauth |
| `CADDY_AUTH_USER` | Username for basicauth |

## ➕ Adding a New Service

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

2. **Create service config** at `configs/myservice/docker-compose.yml`:

```yaml
services:
  myservice:
    image: myimage:latest
    container_name: myservice
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      - TZ=${TZ}
```

3. **Deploy**:

```bash
cd ansible && ansible-playbook playbooks/site.yml --limit mljr --tags services
```

## 🔌 Service Hooks (Optional)

Services can include deployment hooks in `configs/{service}/hooks/`:

| Hook | When | Purpose |
|------|------|---------|
| `pre-deploy.sh` | Before `docker compose up` | Validation, preparation |
| `post-deploy.sh` | After `docker compose up` | Initialization, setup |
| `validate.sh` | After post-deploy | Health checks |

## 🐳 Included Services

| Service | Description | Port |
|---------|-------------|------|
| Glance | Dashboard with widgets | 8080 |
| Nightscout | CGM monitoring | 1337 |
| Uptime Kuma | Service monitoring | 3001 |
| ntfy | Push notifications | 2586 |
| GoAccess | Access log analytics | 7890 |
| Bichon | Email archiver | 15630 |

## 🔒 Security

- All connections over Tailscale VPN (no public SSH)
- Caddy handles automatic HTTPS via Let's Encrypt
- Secrets stored in GitHub Secrets, injected at runtime
- Optional basicauth for sensitive services

## 🛠️ Troubleshooting

| Issue | Solution |
|-------|----------|
| Host unreachable | Check Tailscale status, verify inventory hostname |
| Permission denied | Check `ansible_user` and sudo permissions |
| Service not deployed | Verify `enabled: true` and `host` matches inventory |
| Module not found | Run `ansible-galaxy collection install -r requirements.yml` |

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
