# Homelab Setup Guide

This guide will walk you through setting up your homelab automation from scratch.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Tailscale Setup](#tailscale-setup)
3. [SSH Configuration](#ssh-configuration)
4. [Repository Configuration](#repository-configuration)
5. [Testing the Setup](#testing-the-setup)
6. [GitHub Actions Setup](#github-actions-setup)
7. [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Software

- Git installed on your local machine
- SSH client
- Access to your VPS, home server, and Unraid NAS
- Active Tailscale account

### Required Access

- Root or sudo access to all target devices
- Ability to install packages on target devices
- Network connectivity between your devices

## Tailscale Setup

### 1. Install Tailscale on All Devices

#### VPS (Ubuntu/Debian)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

#### Home Server (Ubuntu/Debian)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

#### Unraid NAS
1. Install Tailscale from Unraid's Community Applications
2. Configure and start the plugin
3. Complete authentication

### 2. Note Your Tailscale Hostnames

After setting up Tailscale on all devices, get their hostnames:
```bash
tailscale status
```

Example output:
```
100.x.x.x  vps              user@    linux   -
100.x.x.x  homeserver       user@    linux   -
100.x.x.x  unraid           user@    linux   -
```

Your hostnames will be in the format: `device-name.tailnet-xxxxx.ts.net`

## SSH Configuration (Not needed anymore. Should be fully handled by tailscale)

### 1. Generate SSH Key (if you don't have one)

On your local machine:
```bash
ssh-keygen -t rsa -b 4096 -C "homelab-automation"
```

Save it to: `~/.ssh/id_rsa_homelab`

### 2. Copy SSH Key to All Devices

For each device:
```bash
ssh-copy-id -i ~/.ssh/id_rsa_homelab.pub root@<tailscale-hostname>
```

Replace `<tailscale-hostname>` with your device's Tailscale hostname.

### 3. Test SSH Connections

```bash
ssh -i ~/.ssh/id_rsa_homelab root@vps.tailnet-xxxxx.ts.net
ssh -i ~/.ssh/id_rsa_homelab root@homeserver.tailnet-xxxxx.ts.net
ssh -i ~/.ssh/id_rsa_homelab root@unraid.tailnet-xxxxx.ts.net
```

## Repository Configuration

### 1. Clone the Repository

```bash
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation
```

### 2. Configure Inventory

Edit `inventory.yml` with your actual device information:

```yaml
devices:
  vps:
    hostname: "your-vps.tailnet-xxxxx.ts.net"  # Replace with actual hostname
    user: "root"
    
  homeserver:
    hostname: "your-homeserver.tailnet-xxxxx.ts.net"  # Replace
    user: "root"
    
  unraid:
    hostname: "your-unraid.tailnet-xxxxx.ts.net"  # Replace
    user: "root"

ssh:
  key_path: "~/.ssh/id_rsa_homelab"
```

### 3. Configure Caddy

Copy the example Caddyfile:
```bash
cp configs/caddy/Caddyfile.example configs/caddy/Caddyfile
```

Edit `configs/caddy/Caddyfile` with your domains:
```
your-domain.com {
    reverse_proxy localhost:8080
}

app.your-domain.com {
    reverse_proxy localhost:3000
}
```

### 4. Customize Docker Services

Add your own docker-compose.yml files to `configs/docker/`:

```bash
mkdir configs/docker/my-service
nano configs/docker/my-service/docker-compose.yml
```

## Testing the Setup

### 1. Test on a Single Device

First, test on one device to ensure everything works:

```bash
./scripts/deploy-single.sh vps.tailnet-xxxxx.ts.net root base
```

This will only run the base setup script.

### 2. Test Docker Installation

```bash
./scripts/deploy-single.sh vps.tailnet-xxxxx.ts.net root docker
```

### 3. Test Full Deployment

```bash
./scripts/deploy-single.sh vps.tailnet-xxxxx.ts.net root all
```

### 4. Verify Services

After deployment, check that services are running:

```bash
ssh root@vps.tailnet-xxxxx.ts.net "docker ps"
```

Access Portainer: `http://<device-ip>:9000`

## GitHub Actions Setup

### 1. Create Tailscale OAuth Client

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "Generate OAuth client"
3. Add tag: `tag:ci`
4. Save the Client ID and Client Secret

### 2. Configure GitHub Secrets

In your GitHub repository, go to Settings > Secrets and variables > Actions

Add these secrets:

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `SSH_PRIVATE_KEY` | `<contents of ~/.ssh/id_rsa_homelab>` | Your SSH private key |
| `TS_OAUTH_CLIENT_ID` | `<from step 1>` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | `<from step 1>` | Tailscale OAuth secret |
| `VPS_HOST` | `vps.tailnet-xxxxx.ts.net` | VPS Tailscale hostname |
| `HOMESERVER_HOST` | `homeserver.tailnet-xxxxx.ts.net` | Home server hostname |
| `UNRAID_HOST` | `unraid.tailnet-xxxxx.ts.net` | Unraid hostname |

### 3. Test GitHub Workflow

1. Go to Actions tab
2. Select "Deploy Homelab"
3. Click "Run workflow"
4. Choose target device: `vps`
5. Choose roles: `base`
6. Click "Run workflow"

Monitor the workflow execution and verify it completes successfully.

## Troubleshooting

### SSH Connection Fails

**Problem**: Cannot connect via SSH

**Solutions**:
- Verify Tailscale is running: `tailscale status`
- Check SSH service is running on target: `systemctl status ssh`
- Verify SSH key permissions: `chmod 600 ~/.ssh/id_rsa_homelab`
- Test basic connectivity: `ping <tailscale-hostname>`

### Docker Installation Fails

**Problem**: Docker installation script fails

**Solutions**:
- Check if Docker is already installed: `docker --version`
- Ensure system is up to date: `apt update && apt upgrade`
- Check disk space: `df -h`
- Review installation logs in the workflow output

### Caddy Fails to Start

**Problem**: Caddy service won't start

**Solutions**:
- Validate Caddyfile syntax: `caddy validate --config /etc/caddy/Caddyfile`
- Check port 80/443 are not in use: `netstat -tlnp | grep :80`
- Review Caddy logs: `journalctl -u caddy -n 50`
- Ensure DNS records point to your server

### GitHub Actions Fails

**Problem**: Workflow fails in GitHub Actions

**Solutions**:
- Verify all secrets are configured correctly
- Check Tailscale OAuth client has correct permissions
- Review workflow logs for specific error messages
- Test deployment locally first with `deploy-single.sh`

### Permission Denied

**Problem**: Scripts fail with permission denied

**Solutions**:
- Make scripts executable: `chmod +x scripts/*.sh`
- Run with appropriate user (root or sudo)
- Check file ownership on target system

## Next Steps

After successful deployment:

1. **Configure your services**: Update Docker Compose files with your preferences
2. **Set up backups**: Implement backup solutions for your data
3. **Monitor your services**: Set up monitoring (Prometheus, Grafana, etc.)
4. **Secure your setup**: Configure firewalls, enable fail2ban
5. **Automate updates**: Use Watchtower or configure automatic updates

## Additional Resources

- [Tailscale Documentation](https://tailscale.com/kb/)
- [Docker Documentation](https://docs.docker.com/)
- [Caddy Documentation](https://caddyserver.com/docs/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

## Need Help?

If you encounter issues not covered here:
1. Check the project's GitHub Issues
2. Review logs from failed deployments
3. Join the Tailscale or Docker community forums
4. Open a new issue in this repository
