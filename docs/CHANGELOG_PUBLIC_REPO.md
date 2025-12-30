# Changelog: Public Repository Implementation

## Date: 2024-12-30

## Summary

Implemented public repository strategy for the homepage application, following the "build-in-public" pattern similar to the existing LibreLink app. Docker images are now built in the public repository and automatically pushed to the public container registry.

## Changes Made

### 1. Updated Sync Workflow

**File**: `.github/workflows/sync-homepage-to-public.yml`

**Changes**:
- Added step to create `.github/workflows/build.yml` in public repo
- Added LICENSE file generation (MIT License)
- Added `repository_dispatch` trigger to public repo after sync
- Build workflow is now created dynamically during sync

**New Workflow Steps**:
```yaml
- Create .github directory structure
- Create build workflow for public repo
- Create LICENSE
- Trigger build in public repository (via repository_dispatch)
```

### 2. Removed Private Build Workflow

**File**: `.github/workflows/build-homepage-image.yml` (REMOVED)

**Reason**: Building in public repo instead to ensure images are automatically public

**Migration Path**: All builds now happen in the public `homepage` repository

### 3. Updated Documentation

**File**: `docs/PUBLIC_REPO_STRATEGY.md`

**Changes**:
- Updated workflow architecture diagram to reflect build-in-public pattern
- Updated file structure to show build.yml in public repo
- Updated deployment example to show new workflow steps
- Updated comparison section to explain why building in public is better

**New File**: `docs/PUBLIC_REPO_SETUP.md`

**Contents**:
- Complete setup instructions for public repository
- Personal Access Token (PAT) creation guide
- Container registry visibility configuration
- Troubleshooting guide
- Security considerations
- Maintenance procedures

## Architecture Changes

### Before (Build in Private)

```
Private Repo → Build Image → Push to Registry (private) → Manual public package config
                    ↓
                Sync Code → Public Repo
```

### After (Build in Public)

```
Private Repo → Sync Code → Public Repo → Build Image → Push to Registry (public)
```

## Benefits

1. **Automatic Public Visibility**: Images are public by default when built in public repo
2. **No Manual Configuration**: No need to manually change package visibility
3. **Standard Pattern**: Follows GitHub's recommended approach
4. **Community Transparency**: Build process visible in public repo
5. **Simpler Workflow**: One-way sync + automatic build

## Security Model

### What Changed

- **Build Location**: Private repo → Public repo
- **Image Visibility**: Manual public config → Automatic public

### What Stayed the Same

- **Secrets Management**: Still passed at runtime via Ansible
- **Source Code Security**: Still synced from private repo (single source of truth)
- **Deployment Security**: Still uses private Ansible inventory with secrets

### Why It's Safe

Docker images contain **compiled code only**, not secrets:

```dockerfile
# What's in the image (safe)
- Compiled Go binary
- Built Svelte static files
- Base OS (Alpine)

# What's NOT in the image (secrets passed at runtime)
- GITHUB_TOKEN
- API keys
- Credentials
```

Secrets are injected at runtime:
```yaml
# docker-compose.yml
environment:
  - GITHUB_TOKEN=${GITHUB_TOKEN}  # From .env file templated by Ansible
```

## Migration Steps for Users

### For First-Time Setup

Follow: `docs/PUBLIC_REPO_SETUP.md`

Key steps:
1. Create public `homepage` repository
2. Add `PUBLIC_REPO_PAT` secret to private repo
3. Trigger initial sync (workflow_dispatch)
4. Verify build completes in public repo
5. Verify images are publicly accessible

### For Existing Deployments

No changes needed! The deployment configuration already uses environment-based image tags:

```yaml
# configs/homepage/docker-compose.yml
image: ghcr.io/mrcodeeu/homepage:${IMAGE_TAG:-latest}
```

```jinja2
# ansible/roles/services/templates/env.j2
IMAGE_TAG={{ 'dev' if env_suffix else 'latest' }}
```

## Workflow Triggers

### Private Repo: sync-homepage-to-public.yml

**Triggers**:
- `push` to `main` branch, paths: `apps/homepage/**`
- `workflow_dispatch` (manual)

**Actions**:
1. Clone public repo
2. Sync source code
3. Create build workflow file
4. Create README and LICENSE
5. Commit and push to public repo
6. Send `repository_dispatch` event to public repo

### Public Repo: build.yml

**Triggers**:
- `push` to `main` or `*dev*` branches
- `repository_dispatch` event type: `sync-complete`
- `workflow_dispatch` (manual)

**Actions**:
1. Checkout code
2. Determine image tag (latest or dev)
3. Build Docker image
4. Push to ghcr.io/mrcodeeu/homepage

## Testing Checklist

- [ ] Create public repository
- [ ] Add PUBLIC_REPO_PAT secret
- [ ] Trigger sync workflow manually
- [ ] Verify sync completes successfully
- [ ] Verify build workflow runs in public repo
- [ ] Verify build completes successfully
- [ ] Test public image pull (no auth): `docker pull ghcr.io/mrcodeeu/homepage:latest`
- [ ] Test local run with env vars
- [ ] Verify Ansible deployment uses public image
- [ ] Test dev branch workflow (if applicable)

## Rollback Plan

If issues arise, rollback by:

1. **Restore private build workflow**:
   ```bash
   git revert <commit-hash-of-removal>
   ```

2. **Disable sync workflow**:
   - Comment out sync-homepage-to-public.yml triggers
   - Or delete the workflow file temporarily

3. **Update deployment to use private images**:
   ```yaml
   # Temporarily change to private registry path if needed
   image: ghcr.io/mrcodeeu/homelab-automation/homepage:latest
   ```

4. **Make package public manually** (if using private build):
   - Go to GitHub Packages settings
   - Change visibility to public

## Known Issues

### Issue: Public repo doesn't exist yet
**Status**: Expected
**Resolution**: Follow setup guide in `docs/PUBLIC_REPO_SETUP.md`

### Issue: First sync fails with "repository not found"
**Status**: Expected on first run
**Resolution**: Create empty public repo first, then re-run sync

### Issue: Build fails with permission denied
**Status**: Possible on first build
**Resolution**: Verify `packages: write` permission in workflow

## Future Enhancements

1. **Add build badges** to public README:
   ```markdown
   ![Docker Image Size](https://img.shields.io/docker/image-size/ghcr.io/mrcodeeu/homepage)
   ![Build Status](https://img.shields.io/github/actions/workflow/status/mrcodeeu/homepage/build.yml)
   ```

2. **Add issue templates** to public repo for community contributions

3. **Add CONTRIBUTING.md** with guidelines for external contributors

4. **Add semantic versioning** with tags (e.g., v1.0.0, v1.1.0)

5. **Add changelog generation** from git commits

## References

- Setup Guide: `docs/PUBLIC_REPO_SETUP.md`
- Strategy Documentation: `docs/PUBLIC_REPO_STRATEGY.md`
- LibreLink Reference: `.github/workflows/build-librelink-image.yml`
- Ansible Deployment: `.github/workflows/ansible-deploy.yml`

## Questions & Support

For questions about this implementation:
1. Review `docs/PUBLIC_REPO_SETUP.md` for setup instructions
2. Review `docs/PUBLIC_REPO_STRATEGY.md` for architectural details
3. Check troubleshooting sections in both documents
4. Review GitHub Actions logs for specific errors

## Contributors

- Implementation: Claude Code AI Assistant
- Review: MrCodeEU
- Pattern Reference: Existing LibreLink app workflow
