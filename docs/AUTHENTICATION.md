# Enabling GoAccess Authentication

## Current Status
Authentication infrastructure is fully implemented but temporarily disabled due to secrets deployment issues.

## What's Already Done
- ✅ `caddy_auth: "basicauth"` field support in services.yml
- ✅ `inject-caddy-secrets.sh` script (uses Python for reliable hash handling)
- ✅ Integration into `setup-caddy.sh`
- ✅ GitHub workflow updated with secret variables
- ✅ Documentation in GITHUB_SECRETS.md

## To Enable Authentication

### 1. Set GitHub Secrets
In your repository settings, add these secrets:
```
CADDY_AUTH_USER=your_username
CADDY_AUTH_PASSWORD_HASH=<bcrypt_hash>
```

Generate the hash with:
```bash
docker run --rm caddy caddy hash-password --plaintext 'your-password'
```

### 2. Re-enable in services.yml
In `configs/services.yml`, change line 54 from:
```yaml
# caddy_auth: "basicauth"  # TODO: Enable basic authentication once secrets are deployed
```

To:
```yaml
caddy_auth: "basicauth"  # Enable basic authentication
```

### 3. Deploy
The GitHub Actions workflow will automatically:
1. Create `secrets.env` with CADDY_AUTH credentials
2. Generate Caddyfile with basicauth placeholders
3. Inject actual credentials via `inject-caddy-secrets.sh`
4. Reload Caddy with authentication enabled

## Testing Authentication
Once enabled:
```bash
# Without auth - should return 401
curl -I https://logs.mljr.eu

# With auth - should return 200
curl -I -u 'username:password' https://logs.mljr.eu
```

## Troubleshooting

### Authentication Not Working
1. Check if placeholders were replaced:
   ```bash
   grep -A 3 'basicauth' /etc/caddy/Caddyfile
   ```
   Should show: `username $2a$14$...` not `__CADDY_AUTH_USER__`

2. Verify secrets exist:
   ```bash
   cat /tmp/homelab-deploy/secrets.env | grep CADDY
   ```

3. Check Caddy logs:
   ```bash
   journalctl -u caddy --since '5 minutes ago' | grep -i 'auth\|401'
   ```

### Bcrypt Hash Issues
- Ensure hash is quoted in secrets.env: `CADDY_AUTH_PASSWORD_HASH='$2a$14$...'`
- The `$` characters must be preserved (single quotes prevent shell interpretation)
- Hash should be exactly 60 characters long

## Technical Details

The authentication flow:
1. `generate-configs.sh` creates Caddyfile with `__CADDY_AUTH_USER__` and `__CADDY_AUTH_PASSWORD_HASH__` placeholders
2. `inject-caddy-secrets.sh` loads secrets.env and replaces placeholders using Python (handles $ in bcrypt hashes)
3. Caddy validates the config and starts with authentication enabled

Caddy's basicauth format:
```
basicauth {
    username bcrypt_hash
}
```
