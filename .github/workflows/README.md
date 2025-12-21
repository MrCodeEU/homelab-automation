# GitHub Actions Deployment Workflow

This directory contains the GitHub Actions workflow for deploying your homelab infrastructure using **Ansible** over Tailscale SSH.

## Workflow

### Ansible Deploy (`ansible-deploy.yml`)

Single unified workflow that deploys to any or all hosts using Ansible playbooks.

**Usage:** Manually trigger via GitHub Actions tab

**Options:**
- **limit**: Target specific hosts (`all`, `mljr`, `homeserver`, `unraid`)
- **tags**: Run specific roles (`all`, `base`, `docker`, `caddy`, `services`)

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Tailscale Authentication
| Secret | Description |
|--------|-------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |

**Setup:**
1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Generate OAuth client credentials
3. Add tag `tag:ci` to the OAuth client permissions

### Application Secrets
| Secret | Description |
|--------|-------------|
| `NIGHTSCOUT_API_SECRET` | Nightscout API authentication secret |
| `LINK_UP_USERNAME` | LibreLink Up account username |
| `LINK_UP_PASSWORD` | LibreLink Up account password |
| `NIGHTSCOUT_API_TOKEN` | Nightscout API token |
| `NIGHTSCOUT_DOMAIN` | Nightscout domain (e.g., `nightscout.example.com`) |
| `BICHON_ENCRYPT_PASSWORD` | Bichon email archiver encryption password |
| `CADDY_AUTH_PASSWORD_HASH` | Bcrypt hash for Caddy basicauth |
| `CADDY_AUTH_USER` | Username for Caddy basicauth |

## How It Works

```
┌─────────────────────┐
│  GitHub Actions     │
│  Runner (Ubuntu)    │
└──────────┬──────────┘
           │
           │ 1. Install Ansible
           │ 2. Set up Tailscale VPN
           ▼
┌─────────────────────┐
│  Tailscale Network  │
└──────────┬──────────┘
           │
           │ 3. Run ansible-playbook
           ▼
┌─────────────────────┐
│  Target Hosts       │
│  (mljr/homeserver/  │
│   pi/unraid)        │
└─────────────────────┘
```

**Workflow steps:**
1. Checkout repository
2. Set up Tailscale VPN connection
3. Install Ansible (cached)
4. Install Ansible collections
5. Run `ansible-playbook playbooks/site.yml` with specified limit/tags

## Ansible Roles (Tags)

| Tag | Description | Hosts |
|-----|-------------|-------|
| `base` | Install base packages (git, curl, vim, htop, etc.) | rocky, debian |
| `docker` | Install Docker and Docker Compose | rocky, debian |
| `caddy` | Install and configure Caddy reverse proxy | rocky |
| `services` | Deploy Docker Compose services | rocky, debian |
| `unraid` | Unraid-specific deployment script | unraid |

## Security Features

- **No SSH keys in repository**: Uses Tailscale authentication
- **Ephemeral connections**: VPN exists only during workflow run
- **Scoped permissions**: OAuth client tagged with `tag:ci`
- **Secrets as env vars**: Injected via Ansible `lookup('env', ...)`
- **No public exposure**: All communication over private Tailscale network

## Troubleshooting

### "Cannot connect to host"
- Verify Tailscale is running on target device
- Check hostname in `ansible/inventory/hosts.yml`
- Ensure `tag:ci` is allowed in your Tailscale ACLs

### "Permission denied"
- Verify user has sudo/root permissions
- Check `ansible_user` in inventory

### "Module not found"
- Run `ansible-galaxy collection install -r requirements.yml`

## Example Usage

### Deploy everything to all hosts:
```bash
# Via GitHub Actions: select limit=all, tags=all
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml
```

### Deploy only to VPS:
```bash
# Via GitHub Actions: select limit=mljr
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --limit mljr
```

### Deploy only Caddy configuration:
```bash
# Via GitHub Actions: select tags=caddy
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --tags caddy
```

### Deploy services to specific host:
```bash
cd ansible && ansible-playbook playbooks/site.yml --limit mljr --tags services
```
