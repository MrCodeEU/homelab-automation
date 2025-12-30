# Public Repository Setup Instructions

This guide explains how to set up the public `homepage` repository and configure it to build Docker images automatically.

## Overview

The homepage follows the **build-in-public** pattern:
- **Private repo** (`homelab-automation`): Development, secrets, infrastructure
- **Public repo** (`homepage`): Source code, Docker builds, community contributions
- **Public registry** (`ghcr.io/mrcodeeu/homepage`): Publicly accessible Docker images

## Why This Works

Docker images contain **compiled code only**, not secrets. Secrets are injected at runtime via environment variables, so we can safely:
1. Build images in the public repo
2. Push to public registry
3. Deploy with runtime secrets from Ansible

See [PUBLIC_REPO_STRATEGY.md](./PUBLIC_REPO_STRATEGY.md) for detailed explanation.

## Prerequisites

- GitHub account with public repository creation rights
- Personal Access Token (PAT) with `repo` and `packages` scopes
- Access to private `homelab-automation` repository secrets

## Step 1: Create Public Repository

### 1.1 Create Repository on GitHub

1. Go to https://github.com/new
2. Repository name: **homepage**
3. Owner: **mrcodeeu** (or your username)
4. Visibility: **Public** ⚠️ Important!
5. **Do NOT** initialize with README (will be synced automatically)
6. Click **Create repository**

### 1.2 Initial Setup

The repository will be empty initially. The first sync will populate it with:
- Source code from `apps/homepage/`
- Build workflow (`.github/workflows/build.yml`)
- Public README
- LICENSE file
- PORTFOLIO.md documentation

## Step 2: Create Personal Access Token

### 2.1 Generate Token

1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click **Generate new token (classic)**
3. Note: `homepage-sync-token`
4. Expiration: Choose based on your security policy (recommend: 90 days with calendar reminder)
5. Select scopes:
   - ✅ **repo** (Full control of private repositories)
   - ✅ **write:packages** (Upload packages to GitHub Package Registry)
   - ✅ **read:packages** (Download packages from GitHub Package Registry)
   - ✅ **delete:packages** (Delete packages from GitHub Package Registry) - optional
6. Click **Generate token**
7. **Copy the token immediately** (you won't see it again!)

### 2.2 Add Token to Private Repository Secrets

1. Go to private repo: https://github.com/mrcodeeu/homelab-automation
2. Settings → Secrets and variables → Actions
3. Click **New repository secret**
4. Name: `PUBLIC_REPO_PAT`
5. Secret: Paste the token from step 2.1
6. Click **Add secret**

## Step 3: Configure Container Registry Visibility

After the first build, make the Docker package public:

### 3.1 Wait for First Build

The first sync will trigger automatically when you push to `apps/homepage/` in the private repo.

Or trigger manually:
1. Go to private repo Actions tab
2. Select "Sync Homepage to Public Repository"
3. Click "Run workflow"
4. Select branch: `main`
5. Click "Run workflow"

### 3.2 Make Package Public

1. Go to https://github.com/mrcodeeu/homepage/packages
2. Click on the **homepage** package
3. Package settings (bottom right) → **Change visibility**
4. Select **Public**
5. Type the repository name to confirm
6. Click **I understand, change package visibility**

⚠️ **Important**: This step is required for anyone to pull images without authentication!

## Step 4: Verify Setup

### 4.1 Check Sync Workflow

1. Private repo Actions: https://github.com/mrcodeeu/homelab-automation/actions
2. Look for ✅ "Sync Homepage to Public Repository"
3. Verify it completed successfully

### 4.2 Check Build Workflow

1. Public repo Actions: https://github.com/mrcodeeu/homepage/actions
2. Look for ✅ "Build and Push Docker Image"
3. Verify it completed successfully

### 4.3 Test Docker Pull (No Authentication)

```bash
# Should work without login
docker pull ghcr.io/mrcodeeu/homepage:latest

# Verify image
docker images | grep homepage
```

### 4.4 Test Homepage Deployment

```bash
# Run locally
docker run -d \
  -p 8080:8080 \
  -e GITHUB_USERNAME=mrcodeeu \
  -e GITHUB_TOKEN=your-github-pat \
  ghcr.io/mrcodeeu/homepage:latest

# Visit http://localhost:8080
curl http://localhost:8080
```

## Step 5: Update Deployment Configuration

The private repo's Ansible deployment should already be configured to use the public image:

**File**: `configs/homepage/docker-compose.yml`
```yaml
services:
  homepage:
    image: ghcr.io/mrcodeeu/homepage:${IMAGE_TAG:-latest}
    # ... rest of config
```

**File**: `ansible/roles/services/templates/env.j2`
```jinja2
IMAGE_TAG={{ 'dev' if env_suffix else 'latest' }}
```

No changes needed - this is already set up!

## Workflow Architecture

### Development Flow

```
1. Developer pushes to apps/homepage/ in private repo
   ↓
2. GitHub Actions: sync-homepage-to-public.yml
   - Copies source code to public repo
   - Creates .github/workflows/build.yml
   - Creates README, LICENSE
   - Commits and pushes
   ↓
3. GitHub Actions (public repo): build.yml
   - Triggered by repository_dispatch (sync-complete)
   - Builds Docker image
   - Pushes to ghcr.io/mrcodeeu/homepage:latest
   ↓
4. ansible-deploy.yml (private repo)
   - Pulls public image
   - Deploys with runtime secrets
```

### Branch Handling

| Branch Pattern | Sync? | Build Tag | Deploy Environment |
|----------------|-------|-----------|-------------------|
| `main` | ✅ Yes | `latest` | Production (`mljr.eu`) |
| `*dev*` | ❌ No | `dev` | Development (`dev.mljr.eu`) |

**Note**: Dev branches do NOT sync to public repo. Only `main` branch syncs.

## Troubleshooting

### Sync fails with "Permission denied"

**Cause**: PAT token missing or incorrect

**Fix**:
1. Verify secret exists: Settings → Secrets → `PUBLIC_REPO_PAT`
2. Check token scopes (needs `repo`, `write:packages`)
3. Generate new token if expired

### Build workflow not triggering

**Cause**: repository_dispatch event not configured

**Fix**:
1. Check public repo has `.github/workflows/build.yml`
2. Verify workflow has `repository_dispatch` trigger:
   ```yaml
   on:
     repository_dispatch:
       types: [sync-complete]
   ```
3. Check sync workflow sends dispatch:
   ```bash
   curl -X POST \
     -H "Authorization: token $TOKEN" \
     https://api.github.com/repos/mrcodeeu/homepage/dispatches \
     -d '{"event_type":"sync-complete"}'
   ```

### Cannot pull image publicly

**Cause**: Package is private

**Fix**: Follow Step 3.2 to make package public

### Wrong image tag deployed

**Cause**: IMAGE_TAG environment variable not set

**Fix**:
1. Check `ansible/roles/services/templates/env.j2`:
   ```jinja2
   IMAGE_TAG={{ 'dev' if env_suffix else 'latest' }}
   ```
2. Verify `env_suffix` is set correctly in `group_vars/all.yml`
3. Check deployment: `cat /opt/homepage/.env | grep IMAGE_TAG`

## Security Considerations

### What's Public

✅ **Safe to be public**:
- Source code (frontend + backend)
- Dockerfile (build instructions)
- Docker images (compiled binaries)
- Build workflows
- Documentation

### What's Private

🔒 **Kept in private repo**:
- GitHub Secrets (API tokens)
- Ansible inventory (server IPs)
- Environment variable values
- Deployment configurations with secrets

### Security Model

**At Build Time** (public repo):
- No secrets needed
- Builds compile code into binaries
- No secrets baked into image

**At Runtime** (private deployment):
- Secrets injected via environment variables
- Ansible templates `.env` file with secrets
- Container pulls public image + private secrets

## Maintenance

### Rotating PAT Token

1. Generate new token (Step 2.1)
2. Update secret in private repo (Step 2.2)
3. Old token can be deleted after verification

### Updating Public README

Edit the README template in:
```
.github/workflows/sync-homepage-to-public.yml
```

Under the "Create public README" step. Changes will sync on next push.

### Adding Build Badges

Add to public README:
```markdown
![Docker Image Size](https://img.shields.io/docker/image-size/ghcr.io/mrcodeeu/homepage)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/mrcodeeu/homepage/build.yml)
![License](https://img.shields.io/github/license/mrcodeeu/homepage)
```

## Next Steps

After setup is complete:

1. ✅ Public repository created and visible
2. ✅ Docker images building automatically
3. ✅ Images publicly accessible (no auth needed)
4. ✅ Deployment using public images + private secrets
5. 📝 Add community contribution guidelines
6. 📝 Add issue templates
7. 📝 Announce public availability

## Reference

- [PUBLIC_REPO_STRATEGY.md](./PUBLIC_REPO_STRATEGY.md) - Detailed strategy explanation
- [GitHub Packages Documentation](https://docs.github.com/en/packages)
- [Docker Build Push Action](https://github.com/docker/build-push-action)
