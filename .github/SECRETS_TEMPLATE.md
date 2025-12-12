# GitHub Secrets Configuration

Copy this template and fill in your values, then add them as GitHub Secrets.

## Tailscale OAuth Credentials

Get these from: https://login.tailscale.com/admin/settings/oauth

```
TS_OAUTH_CLIENT_ID=<your-oauth-client-id>
TS_OAUTH_SECRET=<your-oauth-secret>
```

**Important:** When creating the OAuth client, add the tag `tag:ci` to the permissions.

## VPS Server

```
VPS_USER=root
VPS_HOST=<your-vps-tailscale-hostname>
```

Example: `vps.tailnet-xxxx.ts.net` or IP like `100.x.x.x`

## Home Server

```
HOMESERVER_USER=root
HOMESERVER_HOST=<your-homeserver-tailscale-hostname>
```

Example: `homeserver.tailnet-xxxx.ts.net` or IP like `100.x.x.x`

## Unraid NAS

```
UNRAID_USER=root
UNRAID_HOST=<your-unraid-tailscale-hostname>
```

Example: `unraid.tailnet-xxxx.ts.net` or IP like `100.x.x.x`

---

## How to Add Secrets to GitHub

1. Go to your repository on GitHub
2. Click **Settings**
3. In the left sidebar, click **Secrets and variables** → **Actions**
4. Click **New repository secret**
5. Add each secret with the exact name shown above
6. Click **Add secret**

## Verifying Your Setup

After adding secrets, you can test the setup:

1. Go to **Actions** tab
2. Select one of the deploy workflows (e.g., "Deploy VPS")
3. Click **Run workflow**
4. If it fails with connection errors, check:
   - Tailscale is running on the target device
   - The hostname/IP is correct
   - SSH is enabled on the target device
   - The user has proper permissions

## Finding Your Tailscale Hostnames

Run this on each device:
```bash
tailscale status
```

Or check the Tailscale admin console:
https://login.tailscale.com/admin/machines

## Tailscale ACL Configuration

Make sure your Tailscale ACLs allow the `tag:ci` to access your devices. Add this to your ACL policy:

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
