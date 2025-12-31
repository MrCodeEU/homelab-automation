# Staging Environment Setup

This document explains how the staging environment works for testing changes before deploying to production.

## Overview

The homelab automation repository now supports automatic staging deployments:

- **Production**: Services deployed from the `main` branch are accessible at `<service>.mljr.eu`
- **Development/Staging**: Services deployed from any other branch are accessible at `<service>.dev.mljr.eu`

This allows you to test changes in a production-like environment before merging to main.

## How It Works

### 1. Branch Detection

The GitHub Actions workflow automatically detects the branch being deployed:

```yaml
- name: Set Environment
  id: set-env
  run: |
    IS_STAGING="false"
    ENV_NAME="production"
    # Staging if dispatched with staging=true or if on a non-main branch
    if [ "${{ github.event_name }}" == "workflow_dispatch" ] && [ "${{ inputs.staging }}" == "true" ]; then
      IS_STAGING="true"
      ENV_NAME="staging"
    elif [ "${{ github.ref }}" != "refs/heads/main" ]; then
      IS_STAGING="true"
      ENV_NAME="staging (from branch)"
    fi
```

### 2. Domain Name Generation

The Caddy role templates (`Caddyfile.j2`) automatically add the environment suffix to service domains:

**Production (main branch)**:
- `homepage.mljr.eu`
- `nightscout.mljr.eu`
- `dash.mljr.eu`

**Development (other branches)**:
- `homepage.dev.mljr.eu`
- `nightscout.dev.mljr.eu`
- `dash.dev.mljr.eu`

### 3. Service Configuration

Services are configured the same way for both environments. The only difference is the domain name used by Caddy.

## Usage

### Testing Changes on a Feature Branch

1. **Create a feature branch**:
   ```bash
   git checkout -b add-dev-env
   ```

2. **Make your changes** (e.g., update service configuration, add new service)

3. **Commit and push**:
   ```bash
   git add .
   git commit -m "Add new feature"
   git push origin add-dev-env
   ```

4. **Trigger deployment** (automatic on push or manual via workflow_dispatch):
   - Go to GitHub Actions
   - Select "Ansible Deploy" workflow
   - Click "Run workflow"
   - Select your branch (`add-dev-env`)
   - Click "Run workflow"

5. **Access your service** at `<service>.dev.mljr.eu`:
   ```
   https://homepage.dev.mljr.eu
   ```

6. **Test thoroughly** in the staging environment

7. **Merge to main** when ready:
   ```bash
   git checkout main
   git merge add-dev-env
   git push origin main
   ```

8. **Production deployment** happens automatically, and the service becomes available at:
   ```
   https://homepage.mljr.eu
   ```

## DNS Configuration

You need to configure DNS records for the `.dev` subdomain:

### Option 1: Wildcard DNS (Recommended)
```
*.dev.mljr.eu  A  <your-server-ip>
```

This automatically handles all staging subdomains.

### Option 2: Individual Records
```
homepage.dev.mljr.eu  A  <your-server-ip>
nightscout.dev.mljr.eu  A  <your-server-ip>
dash.dev.mljr.eu  A  <your-server-ip>
```

## Environment Variables

Environment variables are the same for both production and staging.

- `is_staging_deployment` (Ansible variable) - Set to true for staging environments
- `environment_name` (GitHub output) - Set to "production" or "staging"
- All secrets (GITHUB_TOKEN, NIGHTSCOUT_API_SECRET, etc.) remain the same

## Example: Homepage Service

The homepage service is configured in `ansible/inventory/group_vars/all.yml`:

```yaml
- name: homepage
  enabled: true
  domain: "home.mljr.eu"
  port: 8080
  description: "Personal Homepage"
  icon: "mdi:account-circle"
  host: mljr
```

**Production deployment** (main branch):
- Domain: `home.mljr.eu`
- Uses GitHub API with real credentials

**Staging deployment** (add-dev-env branch):
- Domain: `home.dev.mljr.eu`
- Uses GitHub API with real credentials
- Perfect for testing GitHub scraper integration

## Benefits

1. **Test with real APIs**: Staging uses the same environment variables, so you can test GitHub API integration, Strava API, etc.

2. **Production-like environment**: Same infrastructure, same configuration, just different domains

3. **Safe testing**: Changes won't affect production services

4. **Quick iteration**: Push to branch → auto-deploy → test → iterate

5. **Clear separation**: Production and staging services run side-by-side without conflict

## Workflow Integration

The deployment notification includes the environment:

```
✅ Homelab deployment to mljr (env: development, tags: caddy,services) - Deployment Successful
```

This helps you track which environment was deployed.

## Cleanup

Staging services share the same Docker containers as production (just with different Caddy routes). To remove a staging service:

1. Delete the feature branch
2. The Caddy configuration will be updated on the next main branch deployment
3. The staging domain will no longer be accessible

## Limitations

1. **DNS propagation**: New `.dev` subdomains require DNS records

2. **SSL certificates**: Caddy will automatically obtain Let's Encrypt certificates for `.dev` domains

3. **Resource sharing**: Staging services use the same server resources as production

4. **Database/Storage**: Services might share databases/volumes (use different mount points or database names if needed)

## Advanced: Per-Environment Configuration

If you need different configuration for staging vs production, you can use the `is_staging_deployment` variable in templates:

```jinja2
{% if is_staging_deployment | default(false) %}
# Staging-specific configuration
DEBUG=true
{% else %}
# Production-specific configuration
DEBUG=false
{% endif %}
```

## Troubleshooting

### Staging domain not accessible

1. Check DNS records: `dig homepage.dev.mljr.eu`
2. Check Caddy logs: `docker logs caddy`
3. Verify deployment: `docker ps | grep homepage`

### Wrong environment deployed

Check the GitHub Actions logs to see which environment was detected:

```
Set Environment
is_staging_deployment=true
environment_name=staging
```

### Certificate errors

Caddy might take a few minutes to obtain SSL certificates for new domains. Check:

```bash
docker exec caddy cat /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/homepage.dev.mljr.eu/homepage.dev.mljr.eu.crt
```

## Summary

The staging environment provides a safe, automated way to test changes before production deployment. Simply work on a feature branch, push your changes, and test at `<service>.dev.mljr.eu`. When ready, merge to main for production deployment.
