# Deployment Optimization Guide

This document explains the optimizations in place and how to further improve deployment speed and visibility.

## Current Optimizations

### ✅ Already Implemented

1. **Mitogen Strategy** - 40-70% speed improvement via persistent Python interpreters
2. **SSH Connection Multiplexing** - Reuses SSH connections (ControlMaster)
3. **Pipelining** - Reduces SSH round trips by executing multiple commands in one connection
4. **Smart Fact Gathering** - Only gathers facts when needed, caches for 24h
5. **Parallel Execution** - 20 forks for concurrent host operations + free strategy
6. **Async Service Deployment** - Services deploy in parallel, then wait for completion
7. **Fact Caching** - Cached in `/tmp/ansible_facts_cache` for 24 hours
8. **Profile Tasks Callback** - Shows timing for each task
9. **YAML Output** - Cleaner, more readable output
10. **Intelligent Service Deployment** - Auto-detects changed services, only deploys what changed
11. **Parallel Host Deployment** - Optional parallel workflow for multi-host deployments
12. **Idempotent Cleanup** - Disabled/moved services, retired standalone containers, and stale Caddy snippets are reconciled during normal runs
13. **Critical Hook Failure Propagation** - Critical post-deploy hooks fail the Ansible run, workflow summary, and ntfy notification consistently

### GitHub Workflow Improvements

1. **Collapsible Sections** - Long output is grouped and collapsible
2. **Deployment Summary** - Markdown summary with key metrics and changed services
3. **Error Annotations** - Clear error indicators in the UI
4. **Validation Job** - Fails fast on config errors before deployment starts
5. **Change Detection** - Automatically detects which services changed in git diff
6. **Parallel Workflow** - Deploy to multiple hosts simultaneously (optional)
7. **Deployment Status Guard** - The job fails when Ansible returns a non-zero exit code, even if later notification steps still run

## Speed Optimization: Mitogen

**Mitogen is now ENABLED by default** in both local and CI deployments.

It provides 40-70% speed improvement by:
- Using persistent Python interpreters on remote hosts
- Eliminating repeated SSH handshakes
- Reducing module transfer overhead

### Status

✅ **Enabled in CI** - GitHub Actions automatically uses Mitogen
✅ **Enabled in ansible.cfg** - Local deployments use Mitogen by default

### Local Installation

Mitogen is enabled in `ansible.cfg`. Just install it:

```bash
pip install mitogen ansible-mitogen
```

No configuration needed - it's already configured in `ansible.cfg`.

## Output Improvements

### Ansible Callbacks

Current: `yaml` callback for clean output
Available alternatives:
- `json` - Structured output for parsing
- `selective` - Only shows changes
- `actionable` - Minimal output (only failures/changes)

Change in `ansible.cfg`:
```ini
stdout_callback = actionable  # or yaml, json, selective
```

### GitHub Workflow Features

The workflow now provides:

1. **::group:: sections** - Collapse verbose output
2. **Markdown summaries** - `$GITHUB_STEP_SUMMARY` for overview
3. **Error annotations** - `::error::` for failures
4. **Status badges** - Visual status in summary

## Additional Speed Tips

### 1. Conditional Deployment ✅ IMPLEMENTED

The deployment now automatically detects which services changed using git diff:

**How it works:**
- On push: compares current commit with previous
- Detects changed files in `services/` directory
- Only deploys those specific services
- Falls back to full deployment if ansible configs change

**Example output:**
```
📦 Changed services detected: nightscout,homepage
🎯 Targeted deployment: only changed services will be updated
```

**Manual override:**
```bash
# Deploy specific services manually
ansible-playbook playbooks/site.yml -e changed_services=nightscout,homepage
```

### 2. Parallel Host Deployment ✅ IMPLEMENTED

Use the parallel workflow for faster multi-host deployments:

**GitHub Actions:**
- Go to Actions → Deploy Homelab (Parallel) → Run workflow
- Deploys to mljr and nuc simultaneously
- Each host has its own job with independent logs
- Overall deployment time = slowest host (not sum of all)

**When to use:**
- Deploying to multiple hosts
- Need better visibility per host
- Want faster total deployment time

### 3. Skip Unnecessary Tags

When deploying specific services:
```bash
ansible-playbook playbooks/site.yml --tags services,caddy --skip-tags base
```

Avoid skipping `security` when changing CrowdSec enforcement unless you intentionally want to leave the current host enforcement state untouched.

### 4. Reconciliation and Cleanup

Normal full deployments include cleanup tasks:

- `container-reconcile` removes retired standalone containers such as old telemetry agents.
- The `services` role removes Docker Compose services that are no longer assigned to a host.
- The `caddy` role removes orphaned service snippets and regenerates missing snippets.

Use `force_redeploy=true` when hook scripts, `.env` templates, or service files changed but the checksum cache would otherwise skip a service sync.

### 5. Free Strategy (Parallel Tasks)

For independent hosts, use `free` strategy in playbooks:
```yaml
- hosts: all
  strategy: free  # Each host proceeds at its own pace
```

## Monitoring Performance

### Profile Tasks Output

With `profile_tasks` callback enabled, see timing:
```
PLAY RECAP ************************************************************
Tuesday 17 January 2026  10:30:45 +0000 (0:00:02.45)
===============================================================================
Deploy services ------------------------------------------------ 45.32s
Update Docker containers --------------------------------------- 23.14s
Configure Caddy ------------------------------------------------ 12.08s
```

### Workflow Timing

Check the workflow summary for:
- Total runtime
- Per-step duration
- Bottleneck identification

## Troubleshooting

### Slow Fact Gathering

```bash
# Disable facts if not needed
ansible-playbook playbooks/site.yml --tags services --extra-vars "gather_facts=no"
```

### Slow Docker Operations

- Pre-pull images: `docker pull image:tag`
- Use image digests instead of tags
- Enable Docker BuildKit: `DOCKER_BUILDKIT=1`

### Network Latency

- Use Tailscale (already configured)
- Consider SSH compression: Add `-C` to `ssh_args`
- Increase SSH keep-alive: `ServerAliveInterval=15`

## Measuring Success

Track these metrics:
- Deployment duration (5-10min → target: 2-3min with Mitogen)
- Time to first service change
- Failed task identification speed
- Visibility of deployment status

Run `ansible-playbook` with `-vv` for detailed timing information.
