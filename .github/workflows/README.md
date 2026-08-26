# GitHub Actions Deployment Workflows

This directory contains the GitHub Actions workflows for validating and deploying the homelab with OpenVox over Tailscale. The legacy Ansible tree remains available as the migration reference.

## Workflows

### Standard Deploy (`deploy.yml`)

Sequential deployment with validation, OpenVox execution, summary generation, and ntfy notification.

Pull requests use the separate `openvox-pr-check.yml` workflow. Production deployments are manual, scheduled, or service-update dispatches.

### Static Analysis Baseline (`static-analysis.yml`)

Read-only, no-secrets scans using pinned ShellCheck, puppet-lint, actionlint, zizmor, and Gitleaks versions. Each scanner has its own job and uploaded report. A scanner becomes blocking once its findings are fixed or narrowly documented. Puppet lint exempts only the 140-character check because several manifests embed systemd units and configuration files as strings; its structural checks remain blocking.

### IaC Security Scan (`iac-security.yml`)

Read-only Infrastructure-as-Code scanning with Checkov. This workflow intentionally does not receive the Ansible Vault password, Tailscale OAuth credentials, or any production deployment secret. It uploads a Checkov artifact and, when repository settings allow it, SARIF results for GitHub code scanning.

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Tailscale Authentication
| Secret | Description |
|--------|-------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |

**Setup:**
1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Generate OAuth client credentials
3. Add tag `tag:ci` to the OAuth client permissions

### Ansible Vault
| Secret | Description |
|--------|-------------|
| `ANSIBLE_VAULT_PASSWORD` | Password used to decrypt `ansible/inventory/group_vars/all/vault.yml` |

Application secrets live in the encrypted Ansible Vault file. Update `ansible/inventory/group_vars/all/vault.yml.example` and `secrets.yml` when adding a new secret-backed service.

## How It Works

```
┌─────────────────────┐
│  GitHub Actions     │
│  Runner (Ubuntu)    │
└──────────┬──────────┘
           │
           │ 1. Install Ansible
           │ 2. Set up Tailscale VPN
           ▼
┌─────────────────────┐
│  Tailscale Network  │
└──────────┬──────────┘
           │
           │ 3. Run ansible-playbook
           ▼
┌─────────────────────┐
│  Target Hosts       │
│  (mljr/nuc/nas)     │
└─────────────────────┘
```

**Workflow steps:**
1. Checkout repository
2. Set up Tailscale VPN connection
3. Install Ansible, Mitogen, and ARA (cached)
4. Install Ansible collections
5. Decrypt the Ansible Vault password into a temporary file
6. Run `ansible-playbook playbooks/site.yml` with selected limit/tags/check mode
7. Upload ARA run data as a workflow artifact
8. Fail the job when Ansible fails and send deployment notification

The weekly scheduled `deploy.yml` run also sets `docker_prune_enabled=true`, pruning unused Docker images and stopped containers. Volumes are intentionally excluded.

## ARA Reporting

Deployments enable the ARA callback plugin in offline mode. Each run records playbook, task, and host results to `/tmp/ara/ansible.sqlite`, exports basic JSON summaries, and uploads everything as an artifact named `ara-report-<run id>`.

To inspect a downloaded artifact locally:

```bash
pip install "ara[server]"
ARA_DATABASE=sqlite:////path/to/artifact/ara/ansible.sqlite ara playbook list
ARA_DATABASE=sqlite:////path/to/artifact/ara/ansible.sqlite ara host list
```

## IaC Security Scanning

`iac-security.yml` runs Checkov from a pinned PyPI version in a separate, no-secrets workflow. The scan is currently soft-fail so first-run findings can be reviewed and suppressed or fixed without blocking unrelated infrastructure work. After the baseline is clean, switch from `--soft-fail` to severity-based hard failures.

KICS remains a useful secondary scanner, but the Checkmarx GitHub Action and Docker distribution should not be used in this secret-bearing deploy workflow until the supply-chain situation has been reviewed and a trusted, pinned release path is chosen.

## Ansible Roles (Tags)

| Tag | Description | Hosts |
|-----|-------------|-------|
| `base` | Install base packages and Docker | rocky |
| `prune` | Prune unused Docker images/containers | rocky |
| `services` | Deploy Docker Compose services | rocky |
| `caddy` | Configure Caddy reverse proxy | mljr |
| `security` | Security setup and CrowdSec bouncer | mljr |
| `crowdsec` | CrowdSec firewall bouncer | mljr |
| `grafana-alloy` | Monitoring agent | rocky |
| `monitoring` | Monitoring-related roles | rocky |
| `backup` | Backup/restore setup | rocky |

## Security Features

- **No SSH keys in repository**: Uses Tailscale authentication
- **Ephemeral connections**: VPN exists only during workflow run
- **Scoped permissions**: OAuth client tagged with `tag:ci`
- **Secrets in Vault**: Ansible decrypts `vault.yml` with `ANSIBLE_VAULT_PASSWORD`
- **No public exposure**: All communication over private Tailscale network
- **CrowdSec enforcement**: `mljr` installs the nftables firewall bouncer for host-level remediation

## Troubleshooting

### "Cannot connect to host"
- Verify Tailscale is running on target device
- Check hostname in `ansible/inventory/hosts.yml`
- Ensure `tag:ci` is allowed in your Tailscale ACLs

### "Permission denied"
- Verify user has sudo/root permissions
- Check `ansible_user` in inventory

### "Module not found"
- Run `ansible-galaxy collection install -r requirements.yml`

## Example Usage

### Deploy everything to all hosts:
```bash
# Via GitHub Actions: select limit=all, tags=all
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml
```

### Deploy only to VPS:
```bash
# Via GitHub Actions: select limit=mljr
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --limit mljr
```

### Deploy only Caddy configuration:
```bash
# Via GitHub Actions: select tags=caddy
# Or locally:
cd ansible && ansible-playbook playbooks/site.yml --tags caddy
```

### Deploy services to specific host:
```bash
cd ansible && ansible-playbook playbooks/site.yml --limit mljr --tags services
```
