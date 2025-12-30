# Public Repository & Docker Registry Strategy

This document explains how we handle public visibility while keeping secrets secure.

## Overview

```
Private Repo (homelab-automation)
├─ Contains: Source code + Secrets + Infrastructure
├─ Builds: Docker images with secret access
└─ Pushes: Images to public registry (ghcr.io)

Public Repo (homepage)
├─ Contains: Source code only (no secrets)
├─ Purpose: Community visibility, contributions
└─ Uses: Pre-built images from public registry
```

## Why This Works

### Docker Images Don't Contain Secrets

**Build time** (in private repo):
- GitHub Actions has access to secrets
- Docker build process downloads dependencies
- Frontend/backend are compiled
- **No secrets are baked into the image**

**Runtime** (anywhere):
- Secrets are passed as environment variables
- Container pulls from public registry
- Anyone can run: `docker run -e GITHUB_TOKEN=xyz ghcr.io/mrcodeeu/homepage:latest`

### Security Model

```yaml
# ✅ SAFE - Image contains only compiled code
FROM alpine:latest
COPY --from=builder /app/binary .
CMD ["./binary"]

# ❌ UNSAFE - This would bake secrets in (we don't do this!)
ENV GITHUB_TOKEN=ghp_secrettoken123
```

Our approach:
```yaml
# Dockerfile (public) - No secrets
services:
  homepage:
    image: ghcr.io/mrcodeeu/homepage:latest
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}  # Passed at runtime
```

## Workflow Architecture

### 1. Code Changes Flow

```
Developer pushes to private repo
  ↓
GitHub Actions triggers (branch: main or *dev*)
  ↓
┌─────────────────────────────────────┐
│  Build Homepage Image               │
│  - Access to secrets for API calls  │
│  - Builds Docker image              │
│  - Tags: :latest (main) or :dev     │
└─────────────────────────────────────┘
  ↓
Push to ghcr.io/mrcodeeu/homepage
  ↓
┌─────────────────────────────────────┐
│  Sync to Public Repo (main only)    │
│  - Copy source code                 │
│  - Generate public README           │
│  - Remove sensitive files (.env)    │
└─────────────────────────────────────┘
  ↓
Public repo updated (code visible, no secrets)
```

### 2. Deployment Flow

```
Ansible Deploy Workflow
  ↓
Determines environment (main → prod, *dev* → dev)
  ↓
Sets IMAGE_TAG (latest or dev)
  ↓
Docker Compose pulls from public registry
  ↓
Service starts with runtime secrets from Ansible
```

## File Structure

### Private Repo (`homelab-automation`)

```
apps/homepage/
├── frontend/          # SvelteKit app
├── backend/           # Go server
├── Dockerfile         # Multi-stage build
└── README.md          # Internal docs

.github/workflows/
├── build-homepage-image.yml       # Builds & pushes to ghcr.io
├── sync-homepage-to-public.yml    # Syncs code to public repo
└── ansible-deploy.yml             # Deploys with secrets

ansible/
└── roles/services/templates/env.j2  # Runtime secrets
```

### Public Repo (`homepage`)

```
frontend/          # SvelteKit app (synced)
backend/           # Go server (synced)
Dockerfile         # Multi-stage build (synced)
README.md          # Public-facing docs (generated)
PORTFOLIO.md       # Portfolio marker documentation (synced)
LICENSE            # MIT License
.github/           # Issue templates, contribution guide
```

## Docker Registry Details

### Image Tags

| Branch Pattern | Image Tag | Registry | Public? |
|----------------|-----------|----------|---------|
| `main` | `ghcr.io/mrcodeeu/homepage:latest` | GitHub Container Registry | ✅ Yes |
| `*dev*` | `ghcr.io/mrcodeeu/homepage:dev` | GitHub Container Registry | ✅ Yes |

### Pull Access

Anyone can pull without authentication:
```bash
docker pull ghcr.io/mrcodeeu/homepage:latest
```

GitHub Container Registry makes images public automatically when:
1. Repository is public
2. Package visibility is set to public (done via GitHub UI)

## Setting Up a New Public Repo

### Step 1: Create Public Repository

```bash
# On GitHub UI
1. Go to github.com/new
2. Name: homepage
3. Visibility: Public
4. Don't initialize with README (will be synced)
```

### Step 2: Configure Container Registry

```bash
# On GitHub UI
1. Go to github.com/mrcodeeu/homepage/packages
2. Click on 'homepage' package
3. Package settings → Change visibility → Public
```

### Step 3: Add Personal Access Token

```bash
# Create token with repo and packages scope
1. GitHub Settings → Developer settings → Personal access tokens
2. Generate new token (classic)
3. Scopes: repo, write:packages, read:packages
4. Copy token

# Add to private repo secrets
1. homelab-automation → Settings → Secrets
2. New secret: PUBLIC_REPO_PAT
3. Paste token
```

### Step 4: Initial Sync

```bash
# Trigger manually or push to main
git push origin main

# Check Actions tab for:
- ✅ Sync Homepage to Public Repository
- ✅ Build Homepage Image
```

## Community Contributions

### From Public Repo

When someone submits a PR to the public `homepage` repo:

```bash
# Option 1: Manual sync
1. Review PR in public repo
2. Manually copy changes to private repo
3. Test in dev environment
4. Merge in private repo
5. Auto-syncs back to public

# Option 2: Automated sync (future)
1. Set up webhook from public → private
2. Auto-create PR in private repo
3. Review and merge
4. Syncs back to public
```

### Security Review

All contributions are reviewed in private repo before deployment:
- No direct access to secrets
- Changes tested in dev environment
- Manual approval required

## Example: Complete Deployment

### Scenario: Add new feature to homepage

```bash
# 1. Developer creates branch
git checkout -b feature-dev-stats

# 2. Make changes
# Edit apps/homepage/frontend/src/routes/+page.svelte

# 3. Commit and push
git commit -m "feat: add GitHub stats widget"
git push origin feature-dev-stats

# 4. GitHub Actions (automatic)
# - Builds ghcr.io/mrcodeeu/homepage:dev
# - Deploys to dev.mljr.eu
# - Uses runtime secrets from Ansible

# 5. Test at https://dev.mljr.eu

# 6. Merge to main
git checkout main
git merge feature-dev-stats
git push origin main

# 7. GitHub Actions (automatic)
# - Builds ghcr.io/mrcodeeu/homepage:latest
# - Syncs code to public repo
# - Deploys to mljr.eu
# - Public can now pull new image

# 8. Public repo updated
# - Source code visible at github.com/mrcodeeu/homepage
# - README shows: docker pull ghcr.io/mrcodeeu/homepage:latest
```

## Benefits

✅ **Security**: Secrets never leave private repo, not in images
✅ **Visibility**: Public can see code, use images, contribute
✅ **Control**: All builds happen in controlled environment
✅ **Simplicity**: Single source of truth (private repo)
✅ **Community**: Public repo enables contributions
✅ **Testing**: Dev branches deploy to staging automatically

## Comparison with Alternatives

### Alternative 1: Build in Public Repo
❌ Can't access secrets during build
❌ Would need to fork deployment logic
❌ Two build systems to maintain

### Alternative 2: Private Registry
❌ Users can't pull images without authentication
❌ Less community visibility
❌ Harder to showcase

### Our Approach: Build Private, Push Public
✅ Best of both worlds
✅ Secrets stay secure
✅ Images are public
✅ Code is visible

## Troubleshooting

### Image won't pull publicly

```bash
# Check package visibility
https://github.com/mrcodeeu/homepage/packages

# Should show: Public badge
# If not: Package settings → Change visibility → Public
```

### Sync fails

```bash
# Check PAT permissions
- repo (full control)
- write:packages
- read:packages

# Verify secret exists
homelab-automation → Settings → Secrets → PUBLIC_REPO_PAT
```

### Wrong image tag pulled

```bash
# Check deployment environment
echo $ENV_SUFFIX  # Should be empty (prod) or .dev (staging)

# Check .env file on server
cat /opt/homepage/.env | grep IMAGE_TAG
# Should show: IMAGE_TAG=latest (prod) or IMAGE_TAG=dev (staging)
```

## Summary

This strategy allows us to:
1. Keep secrets in private repo (secure)
2. Build with full secret access (functional)
3. Push images to public registry (accessible)
4. Sync code to public repo (visible)
5. Enable community contributions (collaborative)

The key insight: **Docker images contain compiled code, not secrets**. Secrets are injected at runtime via environment variables, so we can safely publish the images publicly.
