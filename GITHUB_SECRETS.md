# GitHub Secrets Configuration

This document lists all the GitHub Secrets that need to be configured in your repository settings for secure deployment.

## 🔐 Required GitHub Secrets

### Infrastructure & Access Secrets

These secrets are used for SSH access and Tailscale connectivity:

| Secret Name | Description | Example Value |
|------------|-------------|---------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth Client ID | `kABcDeFgHiJ1234567` |
| `TS_OAUTH_SECRET` | Tailscale OAuth Client Secret | `tskey-client-kABcDeFgHiJ1234567-xYzAbC123...` |
| `VPS_USER` | SSH username for VPS | `root` or `admin` |
| `VPS_HOST` | Tailscale hostname/IP for VPS | `vps.tailnet-xxxx.ts.net` |
| `HOMESERVER_USER` | SSH username for home server | `admin` |
| `HOMESERVER_HOST` | Tailscale hostname/IP for home server | `homeserver.tailnet-xxxx.ts.net` |
| `SSH_PRIVATE_KEY` | SSH private key for authentication (optional, only for deploy.yml workflow) | `-----BEGIN OPENSSH PRIVATE KEY-----...` |

### Nightscout Application Secrets

These secrets are used for Nightscout CGM monitoring application:

| Secret Name | Description | Example Value | Notes |
|------------|-------------|---------------|-------|
| `NIGHTSCOUT_API_SECRET` | Nightscout master password | `MySecurePassword123!` | Minimum 12 characters |
| `LINK_UP_USERNAME` | LibreLink Up email address | `your-email@example.com` | Your LibreLink account email |
| `LINK_UP_PASSWORD` | LibreLink Up password | `YourLibreLinkPassword123` | Your LibreLink account password |
| `NIGHTSCOUT_API_TOKEN` | SHA1 hash for API authentication | `19b857ecb7a48018b9b0374a1da5bc7172312abd` | Generate with: `echo -n "librelink-connector" \| shasum \| cut -d ' ' -f 1` |
| `NIGHTSCOUT_DOMAIN` | Your Nightscout domain | `nightscout.yourdomain.com` | Domain where Nightscout will be hosted |

### Bichon Mail Archiver Secrets

These secrets are used for Bichon email archiver application:

| Secret Name | Description | Example Value | Notes |
|------------|-------------|---------------|-------|
| `BICHON_ENCRYPT_PASSWORD` | Encryption password for Bichon data | `MyStrongEncryptionKey456!` | Cannot be changed after initial setup without recreating data |

---

## 📋 How to Add GitHub Secrets

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Enter the secret name (exactly as shown above)
5. Enter the secret value
6. Click **Add secret**
7. Repeat for all required secrets

---

## 🔍 Secret Values from Your Current Configuration

Based on your existing `.env.example` files, here are the actual secret values you need to configure in GitHub:

### Nightscout Secrets (from configs/nightscout/.env.example)
```
NIGHTSCOUT_API_SECRET=H0s3nh0d3n124062001
LINK_UP_USERNAME=reinemic2.0@gmail.com
LINK_UP_PASSWORD=QYsw%xgjsRXK$8MF%jfxY6
NIGHTSCOUT_API_TOKEN=19b857ecb7a48018b9b0374a1da5bc7172312abd
NIGHTSCOUT_DOMAIN=nightscout.mljr.eu
```

### Bichon Secrets (from configs/bichon/.env.example)
```
BICHON_ENCRYPT_PASSWORD=SUper_serteestnugreencrypitionpassw0rd!
```

⚠️ **IMPORTANT**: After adding these secrets to GitHub, the values shown above will be removed from the repository to prevent exposure.

---

## ✅ Verification

After configuring all secrets, verify they are set correctly:

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. You should see all the secret names listed (values are hidden for security)
3. Try running a deployment workflow to ensure secrets are being injected correctly

---

## 🔒 Security Best Practices

- ✅ Never commit `.env` files to the repository (already in `.gitignore`)
- ✅ Never commit `secrets.env` files (already in `.gitignore`)
- ✅ Rotate secrets periodically
- ✅ Use strong, unique passwords for each secret
- ✅ Limit repository access to trusted collaborators
- ✅ Review GitHub Actions logs to ensure secrets are not accidentally exposed

---

## 🆘 Troubleshooting

### Deployment fails with "PLACEHOLDER_" values

**Cause**: GitHub Secrets are not configured or have incorrect names.

**Solution**: Verify all secrets are added with the exact names shown above (case-sensitive).

### "Secret not found" error

**Cause**: Secret name mismatch between workflow and secret configuration.

**Solution**: Double-check secret names in GitHub match the names in this document exactly.

### Nightscout deployment fails with configuration error

**Cause**: One or more Nightscout secrets are missing or invalid.

**Solution**: Ensure all 5 Nightscout secrets are configured correctly.

---

## 📚 Additional Resources

- [GitHub Actions: Using secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions)
- [Nightscout Documentation](https://nightscout.github.io/)
- [Tailscale GitHub Actions](https://tailscale.com/kb/1276/tailscale-github-action/)
