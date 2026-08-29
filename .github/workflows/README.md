# GitHub Actions Deployment Workflows

This directory contains the GitHub Actions workflows for validating and deploying the homelab with OpenVox over Tailscale. The `ansible/` tree is retained only as a historical migration reference and has no deployment path of its own.

## Workflows

### Standard Deploy (`deploy.yml`)

Sequential deployment: validate → set up Tailscale → run OpenVox → build deployment status page → notify.

- `workflow_dispatch`: manual run, any branch. Non-`main` branches automatically run in check mode (noop). Inputs: `limit` (`all`/`mljr`/`nuc`/`ugreen`), `staging_services`, `docker_prune`, `reboot_if_needed`.
- `schedule`: weekly, Sunday 00:00 UTC, full apply on all hosts with weekly maintenance (docker prune + gated reboot) enabled.
- `repository_dispatch` (`service-update`): fast path for a single service - resolves the service's host from `openvox/data/common.yaml`'s `services_catalog` and applies just that host (plus mljr for its Caddy snippet).

Pull requests use the separate `openvox-pr-check.yml` workflow, kept out of this one so its reporting/notification steps never run against a dry run.

### OpenVox PR Check (`openvox-pr-check.yml`)

Runs on PRs touching `openvox/**`, `services/**`, `scripts/**`, `tools/**`, `Makefile`, `renovate.json`, `.githooks/pre-commit`, or either of the two OpenVox-related workflow files. `offline-validation` (no secrets) validates Forge modules, `puppet parser validate`/`puppet epp validate`, shell syntax, and `make test`. `live-noop` runs an actual `puppet apply --noop` against all 3 production hosts over Tailscale, but only for same-repo PRs opened by the repo owner (`MrCodeEU`) - fork and external PRs never get production credentials.

### Static Analysis Baseline (`static-analysis.yml`)

Read-only, no-secrets scans using pinned ShellCheck, puppet-lint, actionlint, zizmor, and Gitleaks versions, plus a `go build`/`go vet`/`go mod tidy` check for `tools/`. Each scanner has its own job and uploaded report. Runs unconditionally on every push/PR to `main` (no path filter) - this is what makes its jobs safe to require for merge (see "Branch protection" below). A scanner becomes blocking once its findings are fixed or narrowly documented. Puppet lint exempts only the 140-character check because several manifests embed systemd units and configuration files as strings; its structural checks remain blocking.

### IaC Security Scan (`iac-security.yml`)

Read-only Infrastructure-as-Code scanning with Checkov. This workflow intentionally does not receive Tailscale OAuth credentials or any production deployment secret. It uploads a Checkov artifact and, when repository settings allow it, SARIF results for GitHub code scanning.

Checkov is blocking for active infrastructure. The top-level `ansible/` tree is excluded because it is retained only as the OpenVox migration reference and is no longer a deployment path.

### Claude Code (`claude.yml`, `claude-code-review.yml`)

`claude-code-review.yml` runs an automatic Claude review comment on every PR open/sync. `claude.yml` responds to `@claude` mentions in issues, PR comments, and PR reviews. Both are advisory only - neither is a required status check.

## Branch Protection

The `Main` ruleset on `main` requires a PR (no direct pushes) and has **no bypass actors** - this applies to everyone, including repo admins. Required status checks to merge: `shellcheck`, `puppet-lint`, `actionlint`, `zizmor`, `gitleaks`, `go` (all from `static-analysis.yml`, chosen specifically because none of them are path-filtered, so they always run on every PR).

`openvox-pr-check.yml`'s `offline-validation` and `iac-security.yml`'s `Checkov` are deliberately **not** required checks, even though they're useful - both are path-filtered workflows, and GitHub's required-status-checks does not auto-pass a check that never triggers. Making a path-filtered check required would leave any PR that doesn't touch a matching path (e.g. a doc-only change) permanently stuck on a check that will never report.

`delete_branch_on_merge` is enabled repo-wide - merging a PR (including Renovate's) deletes its branch automatically, no manual cleanup needed.

If a long-lived branch (like a Renovate PR opened before a new required check was added) is missing a required check because its workflow file predates the change, update it onto the latest `main` first (`gh api -X PUT repos/:owner/:repo/pulls/:number/update-branch`, or push a rebase) so the current workflow file - and its required jobs - actually run.

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

Application secrets are stored per-host, encrypted with hiera-eyaml (`openvox/data/common.eyaml`), decrypted locally on each host with its own PKCS7 keypair - there is no fleet-wide secret or vault password for CI to hold. See `openvox/README.md` for the encryption setup.

## How It Works

```
┌─────────────────────┐
│  GitHub Actions     │
│  Runner (Ubuntu)    │
└──────────┬──────────┘
           │
           │ 1. Validate service configs / Caddy templates
           │ 2. Set up Tailscale VPN (tag:ci)
           ▼
┌─────────────────────┐
│  Tailscale Network  │
└──────────┬──────────┘
           │
           │ 3. scripts/openvox-sync.sh <host> <noop|apply>
           │    (rsync manifests, puppet apply on each host)
           ▼
┌─────────────────────┐
│  Target Hosts       │
│  (mljr/nuc/ugreen)  │
└─────────────────────┘
```

**Workflow steps:**
1. Checkout repository
2. Validate service configurations and Caddy templates (`.githooks/pre-commit`)
3. Resolve target hosts (`limit` input, dispatched service, or staging services)
4. Set up Tailscale VPN
5. For each target host, run `scripts/openvox-sync.sh <host> <noop|apply>` (syncs `openvox/` to the host, then runs `puppet apply` there)
6. Upload the combined apply log as a workflow artifact
7. Build and publish the deployment status page (`tools/cmd/build-deploy-status`) to `https://deploy.mljr.eu`
8. Notify via ntfy; fail the job if any host's OpenVox run failed

## Deployment Status Page

Every run (check or apply) publishes a status page to `https://deploy.mljr.eu`, built by `tools/cmd/build-deploy-status` from the OpenVox apply log, the services catalog, and prior deployment history. No separate report download is needed - the page is the record.

## IaC Security Scanning

`iac-security.yml` runs Checkov from a pinned PyPI version in a separate, no-secrets workflow. The scan is currently soft-fail so first-run findings can be reviewed and suppressed or fixed without blocking unrelated infrastructure work. After the baseline is clean, switch from `--soft-fail` to severity-based hard failures.

KICS remains a useful secondary scanner, but the Checkmarx GitHub Action and Docker distribution should not be used in this secret-bearing deploy workflow until the supply-chain situation has been reviewed and a trusted, pinned release path is chosen.

## Security Features

- **No SSH keys in repository**: Uses Tailscale authentication
- **Ephemeral connections**: VPN exists only during workflow run
- **Scoped permissions**: OAuth client tagged with `tag:ci`
- **No fleet-wide secret**: hiera-eyaml, per-host PKCS7 keypairs - a compromised CI runner never holds a key that unlocks more than one host's data
- **No public exposure**: All communication over private Tailscale network
- **CrowdSec enforcement**: `mljr` installs the nftables firewall bouncer for host-level remediation

## Troubleshooting

### "Cannot connect to host"
- Verify Tailscale is running on target device
- Check the host list in `Makefile`'s `OPENVOX_HOSTS`
- Ensure `tag:ci` is allowed in your Tailscale ACLs

### "Permission denied"
- Verify the deploy SSH user has sudo/root permissions on the target host

### OpenVox catalog compile errors
- Run `puppet parser validate` locally (`make test` includes this) before pushing
- Check `openvox/hiera.yaml` data-source ordering if a class parameter isn't resolving as expected

## Example Usage

### Deploy everything to all hosts:
```bash
gh workflow run deploy.yml -f limit=all
# Or locally:
make openvox-deploy
```

### Deploy only to one host:
```bash
gh workflow run deploy.yml -f limit=mljr
# Or locally:
make openvox-deploy-mljr
```

### Dry run (noop) on one host:
```bash
make openvox-check-nuc
```

### Deploy a single service via its catalog entry:
```bash
gh api repos/:owner/:repo/dispatches -f event_type=service-update -f 'client_payload[service]=homepage'
```
