# Migration Guide: Old to New Deployment Workflows

This guide helps you migrate from the old SSH key-based deployment to the new Tailscale-based deployment workflows.

## What's Changed?

### Old Approach (`deploy.yml`)
- ✗ Required SSH private key stored in GitHub Secrets
- ✗ Manual SSH host key scanning
- ✗ Single monolithic workflow
- ✗ Could not test individual devices without deploying all
- ✗ Direct SSH connections (potential security issues)

### New Approach (4 workflows)
- ✓ Uses Tailscale OAuth (no SSH keys in GitHub!)
- ✓ Automatic secure Tailscale connection
- ✓ Modular: 3 individual device workflows + 1 full deployment
- ✓ Test each device independently
- ✓ Better security with ephemeral Tailscale connections
- ✓ Cleaner, more maintainable code

## Migration Steps

### Step 1: Set Up Tailscale OAuth

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click **Generate OAuth client**
3. Add description: "GitHub Actions CI"
4. Add tag: `tag:ci`
5. Click **Generate client**
6. Save the Client ID and Secret (you'll need these in Step 3)

### Step 2: Update Tailscale ACLs

Add this to your Tailscale ACL policy to allow GitHub Actions to access your devices:

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

### Step 3: Update GitHub Secrets

**Remove old secrets:**
- `SSH_PRIVATE_KEY` (no longer needed!)

**Add new secrets:**

Navigate to your repository → Settings → Secrets and variables → Actions

1. **Tailscale OAuth credentials:**
   - Name: `TS_OAUTH_CLIENT_ID`
   - Value: [from Step 1]
   
   - Name: `TS_OAUTH_SECRET`
   - Value: [from Step 1]

2. **VPS credentials:**
   - Name: `VPS_USER`
   - Value: `root` (or your SSH username)
   
   - Name: `VPS_HOST`
   - Value: Your VPS Tailscale hostname (e.g., `vps.tailnet-xxx.ts.net`)

3. **Home Server credentials:**
   - Name: `HOMESERVER_USER`
   - Value: `root` (or your SSH username)
   
   - Name: `HOMESERVER_HOST`
   - Value: Your home server Tailscale hostname

4. **Unraid credentials:**
   - Name: `UNRAID_USER`
   - Value: `root`
   
   - Name: `UNRAID_HOST`
   - Value: Your Unraid Tailscale hostname

### Step 4: Verify Tailscale on Target Devices

Ensure Tailscale is running on all devices:

```bash
# On each device, run:
tailscale status

# Should show connected devices and your tailnet info
```

If Tailscale is not installed, install it:
```bash
# Rocky Linux / CentOS / RHEL
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up

# Unraid
# Install via Community Applications or:
# Settings → Plugins → Install Plugin → paste Tailscale plugin URL
```

### Step 5: Test Individual Workflows

Start with testing one device before deploying to all:

1. Go to **Actions** tab
2. Select **Deploy VPS** (or whichever device you want to test)
3. Click **Run workflow**
4. Choose roles (start with just `base` for testing)
5. Click **Run workflow**
6. Watch the logs to ensure it works

If successful, repeat for other devices.

### Step 6: Remove Old Workflow (Optional)

Once you've verified the new workflows work:

1. Delete or rename `.github/workflows/deploy.yml`
2. Commit the change

Or keep it as a backup until you're fully confident in the new setup.

## Troubleshooting Migration Issues

### "Context access might be invalid" errors in VS Code

These are just warnings that secrets aren't configured yet. They'll disappear once you add the secrets to GitHub.

### "Cannot connect to [hostname]"

**Check:**
- Is Tailscale running on the target device? (`tailscale status`)
- Is the hostname correct? (Check Tailscale admin console)
- Are your ACLs configured to allow `tag:ci` → device:22?

**Fix:**
```bash
# On target device
sudo systemctl status tailscaled
sudo systemctl start tailscaled
tailscale up
```

### "Permission denied (publickey)"

**Check:**
- Is SSH enabled on the target device?
- Does the user have proper permissions?
- Can you SSH manually via Tailscale?

**Test manually:**
```bash
# On your local machine (with Tailscale running)
tailscale ssh root@vps.tailnet-xxx.ts.net
```

### "OAuth authentication failed"

**Check:**
- Are Client ID and Secret correct?
- Did you add `tag:ci` to the OAuth client?
- Are the secrets named exactly: `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`?

## Key Differences in Workflow Behavior

### Old Workflow
```yaml
# Required SSH key setup
- name: Setup SSH key
  run: |
    mkdir -p ~/.ssh
    echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa
    ssh-keyscan -H ${{ secrets.VPS_HOST }} >> ~/.ssh/known_hosts
```

### New Workflow
```yaml
# Just set up Tailscale!
- name: Set up Tailscale
  uses: tailscale/github-action@v3
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
```

Much cleaner and more secure!

## Benefits After Migration

✅ **No SSH Keys to Manage**: Tailscale handles authentication  
✅ **Better Security**: Ephemeral connections, no long-lived credentials  
✅ **Individual Testing**: Test each device without affecting others  
✅ **Parallel Development**: Work on different devices simultaneously  
✅ **Clearer Logs**: Each device gets its own workflow run with isolated logs  
✅ **Faster Debugging**: Don't wait for all devices when only one fails  

## Rollback Plan

If you need to rollback to the old workflow:

1. Re-add `SSH_PRIVATE_KEY` secret
2. Rename old `deploy.yml` back (if you renamed it)
3. Keep the old secrets around for a while as backup

## Questions?

See the full documentation:
- [Workflow README](.github/workflows/README.md)
- [Secrets Template](.github/SECRETS_TEMPLATE.md)
- [Main README](../README.md)
