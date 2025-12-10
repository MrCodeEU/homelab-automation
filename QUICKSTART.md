# Quick Start Guide

Get your homelab up and running in minutes!

## Prerequisites Checklist

- [ ] Tailscale installed on all devices
- [ ] SSH access configured to all devices
- [ ] Git installed on your local machine
- [ ] SSH key generated

## 5-Minute Setup

### 1. Clone and Configure (2 minutes)

```bash
# Clone the repository
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation

# Edit inventory with your Tailscale hostnames
nano inventory.yml
```

Update these lines:
```yaml
vps:
  hostname: "your-vps.tailnet-xxxxx.ts.net"  # Change this
homeserver:
  hostname: "your-homeserver.tailnet-xxxxx.ts.net"  # Change this
unraid:
  hostname: "your-unraid.tailnet-xxxxx.ts.net"  # Change this
```

### 2. Test Connection (1 minute)

```bash
# Test SSH connection to your VPS
ssh root@your-vps.tailnet-xxxxx.ts.net
exit
```

### 3. Deploy! (2 minutes)

```bash
# Deploy to your VPS
./scripts/deploy-single.sh your-vps.tailnet-xxxxx.ts.net root all

# Deploy to your home server
./scripts/deploy-single.sh your-homeserver.tailnet-xxxxx.ts.net root all

# Deploy to your Unraid NAS
./scripts/deploy-single.sh your-unraid.tailnet-xxxxx.ts.net root all
```

## What Gets Installed?

### On All Devices
- Essential packages (git, curl, wget, vim, htop)
- Docker and Docker Compose
- Portainer (Docker management UI)
- Watchtower (auto-updates containers)

### On VPS and Home Server
- Caddy reverse proxy (with automatic HTTPS)
- Homepage dashboard

## Access Your Services

After deployment:

- **Portainer**: `http://<device-ip>:9000`
- **Homepage**: `http://<device-ip>:3000`

## Next Steps

1. **Customize Docker Services**: Add your own services in `configs/docker/`
2. **Configure Caddy**: Set up your domains in `configs/caddy/Caddyfile`
3. **Set up GitHub Actions**: For automated deployments (see SETUP.md)

## Common Issues

**Can't connect via SSH?**
```bash
# Check Tailscale status
tailscale status

# Verify SSH key permissions
chmod 600 ~/.ssh/id_rsa
```

**Script permission denied?**
```bash
# Make scripts executable
chmod +x scripts/*.sh
```

**Need more help?**
- See [SETUP.md](SETUP.md) for detailed instructions
- Check [README.md](README.md) for complete documentation

## Pro Tips

💡 **Test on one device first** before deploying to all

💡 **Use `deploy-single.sh`** for testing and manual deployments

💡 **Check logs** if something fails:
```bash
ssh root@<hostname> "docker logs <container>"
```

💡 **Deploy specific roles**:
```bash
# Only install base packages
./scripts/deploy-single.sh <hostname> root base

# Only Docker (skips base)
./scripts/deploy-single.sh <hostname> root docker
```

## That's It!

You now have a fully automated homelab setup. 🎉

For detailed configuration and advanced features, check out:
- [SETUP.md](SETUP.md) - Detailed setup guide
- [README.md](README.md) - Complete documentation
