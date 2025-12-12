# 🚀 Deployment Setup Checklist

Use this checklist to set up your new Tailscale-based deployment system.

## Phase 1: Tailscale Setup

### On Your Devices

- [ ] **VPS**: Tailscale installed and running
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  tailscale status  # Verify connection
  ```

- [ ] **Home Server**: Tailscale installed and running
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  tailscale status
  ```

- [ ] **Unraid**: Tailscale installed via Community Applications
  - Settings → Plugins → Install Tailscale plugin
  - Configure and start Tailscale
  - Verify in Tailscale admin console

### In Tailscale Admin Console

- [ ] Note down Tailscale hostnames for all devices
  - VPS: `___________________________`
  - Home Server: `___________________________`
  - Unraid: `___________________________`

- [ ] Generate OAuth client credentials
  - Go to: https://login.tailscale.com/admin/settings/oauth
  - Click "Generate OAuth client"
  - Description: "GitHub Actions CI"
  - Add tag: `tag:ci`
  - Save credentials:
    - Client ID: `___________________________`
    - Client Secret: `___________________________`

- [ ] Update ACL policy to allow `tag:ci`
  ```json
  {
    "tagOwners": {
      "tag:ci": ["autogroup:admin"]
    },
    "acls": [
      {
        "action": "accept",
        "src": ["tag:ci"],
        "dst": ["*:22"]
      }
    ]
  }
  ```

## Phase 2: GitHub Secrets Configuration

Go to: Repository → Settings → Secrets and variables → Actions

### Tailscale Secrets
- [ ] Add `TS_OAUTH_CLIENT_ID` (from Phase 1)
- [ ] Add `TS_OAUTH_SECRET` (from Phase 1)

### VPS Secrets
- [ ] Add `VPS_USER` (usually: `root`)
- [ ] Add `VPS_HOST` (your VPS Tailscale hostname)

### Home Server Secrets
- [ ] Add `HOMESERVER_USER` (usually: `root`)
- [ ] Add `HOMESERVER_HOST` (your home server Tailscale hostname)

### Unraid Secrets
- [ ] Add `UNRAID_USER` (usually: `root`)
- [ ] Add `UNRAID_HOST` (your Unraid Tailscale hostname)

**Total secrets: 8** ✓

## Phase 3: Verify SSH Access

Test SSH connectivity from your local machine (with Tailscale running):

- [ ] Test VPS connection
  ```bash
  tailscale ssh root@vps.tailnet-xxx.ts.net "echo 'VPS OK'"
  ```

- [ ] Test Home Server connection
  ```bash
  tailscale ssh root@homeserver.tailnet-xxx.ts.net "echo 'Homeserver OK'"
  ```

- [ ] Test Unraid connection
  ```bash
  tailscale ssh root@unraid.tailnet-xxx.ts.net "echo 'Unraid OK'"
  ```

All should print the echo message successfully.

## Phase 4: Test Individual Deployments

Start with the simplest role (`base`) on each device:

### VPS Test
- [ ] Go to Actions tab → "Deploy VPS"
- [ ] Click "Run workflow"
- [ ] Select role: `base`
- [ ] Click "Run workflow"
- [ ] Wait for completion (should be ✅ green)
- [ ] Review logs for any issues

### Home Server Test
- [ ] Go to Actions tab → "Deploy Home Server"
- [ ] Click "Run workflow"
- [ ] Select role: `base`
- [ ] Click "Run workflow"
- [ ] Wait for completion
- [ ] Review logs

### Unraid Test
- [ ] Go to Actions tab → "Deploy Unraid"
- [ ] Click "Run workflow"
- [ ] Select role: `base`
- [ ] Click "Run workflow"
- [ ] Wait for completion
- [ ] Review logs

## Phase 5: Full Role Deployment

Once individual tests pass, deploy all roles:

### VPS Full Deployment
- [ ] Deploy VPS with role: `all`
- [ ] Verify Docker installed
- [ ] Verify Caddy configured
- [ ] Check all services running

### Home Server Full Deployment
- [ ] Deploy Home Server with role: `all`
- [ ] Verify Docker installed
- [ ] Verify Caddy configured
- [ ] Check all services running

### Unraid Full Deployment
- [ ] Deploy Unraid with role: `all`
- [ ] Verify Docker containers running
- [ ] Check Unraid dashboard for containers

## Phase 6: Full Homelab Deployment

Now test the complete deployment workflow:

- [ ] Go to Actions tab → "Deploy All Devices"
- [ ] Click "Run workflow"
- [ ] Select role: `all`
- [ ] Click "Run workflow"
- [ ] Watch sequential deployment:
  1. VPS deploys
  2. Home Server deploys (after VPS success)
  3. Unraid deploys (after Home Server success)
- [ ] Verify all three show ✅ success
- [ ] Check deployment summary

## Phase 7: Cleanup (Optional)

- [ ] Review and test all deployments working correctly
- [ ] Remove or archive old `deploy.yml` workflow
- [ ] Remove old `SSH_PRIVATE_KEY` secret (no longer needed)
- [ ] Update any documentation referencing old workflow

## Phase 8: Verify Services

Check that all deployed services are running:

### On VPS
- [ ] Docker: `docker ps`
- [ ] Portainer: http://vps-ip:9000
- [ ] Caddy: `systemctl status caddy`
- [ ] Homepage: http://vps-ip:3000

### On Home Server
- [ ] Docker: `docker ps`
- [ ] Portainer: http://homeserver-ip:9000
- [ ] Caddy: `systemctl status caddy`
- [ ] Homepage: http://homeserver-ip:3000

### On Unraid
- [ ] Docker containers: Check Unraid dashboard → Docker tab
- [ ] Portainer: http://unraid-ip:9000
- [ ] Homepage: http://unraid-ip:3000

## 🎉 Completion

- [ ] All workflows tested and working
- [ ] All services deployed and running
- [ ] Documentation reviewed
- [ ] Celebrate! 🍾

## 📝 Notes & Issues

Use this space to track any issues or notes during setup:

```
_____________________________________________________________

_____________________________________________________________

_____________________________________________________________

_____________________________________________________________

_____________________________________________________________
```

## 🆘 Troubleshooting Reference

If something fails, check:

1. **Tailscale connectivity**: `tailscale status` on all devices
2. **GitHub Secrets**: All 8 secrets configured correctly?
3. **SSH access**: Can you manually SSH via Tailscale?
4. **ACLs**: Is `tag:ci` allowed in your Tailscale ACLs?
5. **Logs**: Check GitHub Actions logs for specific error messages

See [workflows/README.md](.github/workflows/README.md) for detailed troubleshooting.

## 📚 Resources

- [Workflow Documentation](.github/workflows/README.md)
- [Secrets Template](.github/SECRETS_TEMPLATE.md)
- [Migration Guide](.github/MIGRATION.md)
- [Deployment Summary](.github/DEPLOYMENT_SUMMARY.md)

---

**Last Updated**: [Fill in date when you complete setup]  
**Status**: [ ] Not Started | [ ] In Progress | [ ] Complete
