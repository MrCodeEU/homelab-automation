# GitHub Actions Deployment Workflows

This directory contains GitHub Actions workflows for deploying your homelab infrastructure using Tailscale SSH.

## Available Workflows

### 1. Deploy All Devices (`deploy-all.yml`)
Deploys to all devices sequentially (VPS → Home Server → Unraid).

**Usage:** Manually trigger via GitHub Actions tab
- **When to use:** Full homelab setup or synchronized updates across all devices
- **Deployment order:** VPS first, then Home Server, then Unraid
- **Failure handling:** If one device fails, subsequent devices won't be deployed

### 2. Deploy VPS (`deploy-vps.yml`)
Deploys only to your VPS server.

**Usage:** Manually trigger via GitHub Actions tab
- **When to use:** Testing VPS-specific changes without affecting other devices
- **OS:** Rocky Linux
- **Available roles:** base, docker, caddy

### 3. Deploy Home Server (`deploy-homeserver.yml`)
Deploys only to your home server.

**Usage:** Manually trigger via GitHub Actions tab
- **When to use:** Testing home server changes in isolation
- **OS:** Rocky Linux
- **Available roles:** base, docker, caddy

### 4. Deploy Unraid (`deploy-unraid.yml`)
Deploys only to your Unraid NAS.

**Usage:** Manually trigger via GitHub Actions tab
- **When to use:** Testing Unraid-specific changes
- **OS:** Slackware (Unraid)
- **Available roles:** base, docker (no caddy)

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Tailscale Authentication
- `TS_OAUTH_CLIENT_ID` - Tailscale OAuth client ID
- `TS_OAUTH_SECRET` - Tailscale OAuth secret

**Setup instructions:**
1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Generate OAuth client credentials
3. Add tag `tag:ci` to the OAuth client permissions

### VPS Configuration
- `VPS_USER` - SSH username (usually `root`)
- `VPS_HOST` - Tailscale hostname or IP (e.g., `vps.tailnet-xxxx.ts.net`)

### Home Server Configuration
- `HOMESERVER_USER` - SSH username (usually `root`)
- `HOMESERVER_HOST` - Tailscale hostname or IP (e.g., `homeserver.tailnet-xxxx.ts.net`)

### Unraid Configuration
- `UNRAID_USER` - SSH username (usually `root`)
- `UNRAID_HOST` - Tailscale hostname or IP (e.g., `unraid.tailnet-xxxx.ts.net`)

## Deployment Roles

Each workflow allows you to select which roles to deploy:

- **all**: Deploy all applicable roles (default)
- **base**: Base system setup (packages, configuration)
- **docker**: Docker installation and configuration
- **caddy**: Caddy reverse proxy setup (VPS and Home Server only)
- **base,docker**: Combination of base and docker roles
- **base,docker,caddy**: All roles together

## How It Works

1. **Checkout**: Retrieves your repository code
2. **Tailscale Setup**: Establishes secure Tailscale VPN connection
3. **SSH Connection**: Tests connectivity to target device
4. **File Transfer**: Copies scripts and configs to `/tmp/homelab-deploy` on remote host
5. **Execution**: Runs deployment scripts based on selected roles
6. **Reporting**: Provides deployment summary and status

## Deployment Flow

```
┌─────────────────────┐
│  GitHub Actions     │
│  Runner (Ubuntu)    │
└──────────┬──────────┘
           │
           │ 1. Set up Tailscale
           ▼
┌─────────────────────┐
│  Tailscale Network  │
└──────────┬──────────┘
           │
           │ 2. SSH over Tailscale
           ▼
┌─────────────────────┐
│  Target Device      │
│  (VPS/Home/Unraid)  │
│                     │
│  /tmp/homelab-      │
│    deploy/          │
│    ├── scripts/     │
│    └── configs/     │
└─────────────────────┘
```

## Security Features

- **No SSH keys in repository**: Uses Tailscale authentication
- **Ephemeral connections**: Tailscale VPN connection exists only during workflow run
- **Scoped permissions**: OAuth client tagged with `tag:ci`
- **Secrets management**: All sensitive data stored as GitHub Secrets
- **No public exposure**: All communication over private Tailscale network

## Troubleshooting

### "Cannot connect to host"
- Verify Tailscale is running on target device
- Check that device hostname matches GitHub Secret
- Ensure `tag:ci` is allowed in your Tailscale ACLs

### "Permission denied"
- Verify SSH is enabled on target device
- Check that user has proper permissions (root or sudo)

### "Script not found"
- Ensure all scripts in `scripts/` directory are present
- Check that scripts are executable (`chmod +x scripts/*.sh`)

### Workflow fails but you want to continue testing
- Use individual device workflows instead of deploy-all
- This prevents cascading failures across all devices

## Migration from Old Workflow

The old `deploy.yml` used SSH keys and manual host configuration. Key differences:

**Old approach:**
- Required SSH private key in secrets
- Manual SSH host key scanning
- Direct SSH connections

**New approach:**
- Uses Tailscale authentication (OAuth)
- No SSH keys needed
- Automatic secure connection via Tailscale
- Better security with ephemeral access

## Best Practices

1. **Test individually first**: Use per-device workflows to test changes
2. **Use deploy-all for production**: Once tested, deploy to all devices together
3. **Check logs**: Review workflow logs for detailed deployment information
4. **Keep secrets updated**: Rotate OAuth credentials periodically
5. **Version control**: Always test scripts locally before committing

## Example Usage

### Test VPS changes only:
1. Go to Actions tab
2. Select "Deploy VPS" workflow
3. Click "Run workflow"
4. Select roles to deploy
5. Click "Run workflow"

### Deploy to all devices:
1. Go to Actions tab
2. Select "Deploy All Devices" workflow
3. Click "Run workflow"
4. Select "all" for roles
5. Click "Run workflow"

### Deploy only Docker updates:
1. Select appropriate workflow
2. Choose "docker" role
3. Run workflow
