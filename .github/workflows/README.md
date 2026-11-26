# GitHub Actions Deployment Workflows

This directory contains the GitHub Actions workflows for validating and deploying the homelab with OpenVox. No workflow reaches a host: deploys are signed requests the hosts' deploy agents pull (docs/DEPLOY_AGENT.md). The `ansible/` tree is retained only as a historical migration reference and has no deployment path of its own.

## Workflows

### Standard Deploy (`deploy.yml`)

Creates one signed deploy request per host (job `request`); each host's deploy agent applies it and reports the result.

- `workflow_dispatch`: manual run, any branch. Non-`main` branches automatically run in check mode (noop). Inputs: `limit` (`all`/`mljr`/`nuc`/`ugreen`), `staging_services`, `docker_prune`, `reboot_if_needed`.
- `schedule`: weekly, Saturday 18:00 UTC, full apply of main on all hosts. Weekly maintenance (updates, docker prune, gated reboot) is the deploy agents' own window, Sundays from 01:00 local (docs/DEPLOY_AGENT.md).
- `repository_dispatch` (`service-update`): fast path for a single service - resolves the service's host from `openvox/data/common.yaml`'s `services_catalog` and applies just that host (plus mljr for its Caddy snippet). Only that service pulls its image; the others are brought up with the images they have. An optional `client_payload[tag]` (production only, `latest` = none) pins the service to that image tag until a dispatch without one (docs/DEPLOY_AGENT.md).

Pull requests use the separate `openvox-pr-check.yml` workflow, kept out of this one so its reporting/notification steps never run against a dry run.

### OpenVox PR Check (`openvox-pr-check.yml`)

Runs on PRs touching `openvox/**`, `services/**`, `scripts/**`, `tools/**`, `Makefile`, `renovate.json`, `.githooks/pre-commit`, or either of the two OpenVox-related workflow files. `offline-validation` (no secrets) validates Forge modules, `puppet parser validate`/`puppet epp validate`, shell syntax, and `make test`. `Catalog diff` compiles every host's catalog for base and head without hosts or secrets and shows the difference (`scripts/catalog-diff.sh`). No job reaches a host: the live noop over Tailscale was removed on 2026-11-20 (docs/DEPLOY_AGENT.md).

### Static Analysis Baseline (`static-analysis.yml`)

Read-only, no-secrets scans using pinned ShellCheck, puppet-lint, actionlint, zizmor, and Gitleaks versions, plus a `go build`/`go vet`/`go mod tidy` check for `tools/`. Each scanner has its own job and uploaded report. Runs unconditionally on every push/PR to `main` (no path filter) - this is what makes its jobs safe to require for merge (see "Branch protection" below). A scanner becomes blocking once its findings are fixed or narrowly documented. Puppet lint exempts only the 140-character check because several manifests embed systemd units and configuration files as strings; its structural checks remain blocking.

### IaC Security Scan (`iac-security.yml`)

Read-only Infrastructure-as-Code scanning with Checkov. This workflow intentionally does not receive Tailscale OAuth credentials or any production deployment secret. It uploads a Checkov artifact and, when repository settings allow it, SARIF results for GitHub code scanning.

Checkov is blocking for active infrastructure. The top-level `ansible/` tree is excluded because it is retained only as the OpenVox migration reference and is no longer a deployment path.

## Branch Protection

The `Main` ruleset on `main` requires a PR (no direct pushes) and has **no bypass actors** - this applies to everyone, including repo admins. Required status checks to merge: `shellcheck`, `puppet-lint`, `actionlint`, `zizmor`, `gitleaks`, `go` (all from `static-analysis.yml`, chosen specifically because none of them are path-filtered, so they always run on every PR).

`openvox-pr-check.yml`'s `offline-validation` and `iac-security.yml`'s `Checkov` are deliberately **not** required checks, even though they're useful - both are path-filtered workflows, and GitHub's required-status-checks does not auto-pass a check that never triggers. Making a path-filtered check required would leave any PR that doesn't touch a matching path (e.g. a doc-only change) permanently stuck on a check that will never report.

`delete_branch_on_merge` is enabled repo-wide - merging a PR (including Renovate's) deletes its branch automatically, no manual cleanup needed.

If a long-lived branch (like a Renovate PR opened before a new required check was added) is missing a required check because its workflow file predates the change, update it onto the latest `main` first (`gh api -X PUT repos/:owner/:repo/pulls/:number/update-branch`, or push a rebase) so the current workflow file - and its required jobs - actually run.

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

No workflow reaches a host, so there are no Tailscale or SSH credentials in CI. The Tailscale OAuth client (`TS_OAUTH_*`, `tag:ci`) and the `production-check` environment were removed on 2026-11-20, together with `openvox-drift.yml`: each deploy agent runs the daily drift check on its own host (docs/DEPLOY_AGENT.md).

Application secrets are stored per-host, encrypted with hiera-eyaml (`openvox/data/common.eyaml`), decrypted locally on each host with its own PKCS7 keypair - there is no fleet-wide secret or vault password for CI to hold. See `openvox/README.md` for the encryption setup.

## How It Works

`deploy.yml` deploys nothing itself and has no path to a host (docs/DEPLOY_AGENT.md):

1. `validate`: service configurations and Caddy templates (`.githooks/pre-commit`).
2. On a non-main branch (`workflow_dispatch`), job `check`: the catalog diff from each host's deployed commit (`scripts/catalog-check.sh`). Nothing is deployed.
3. On main, job `request`: resolve the target hosts (`limit` input, dispatched service, or staging services), then create a GitHub-signed request on `deploy/<host>` per host (`scripts/deploy-request.sh`).
4. Each host's deploy-agent picks its request up within a minute, verifies it, applies it, and reports the result itself: ntfy `/deployment` (mail fallback), metrics, healthreport. A failed apply does not turn this workflow red.

## Deployment Status Page

`https://deploy.mljr.eu` was built by `deploy.yml` from the push's apply log (`tools/cmd/build-deploy-status`). Since the push is gone (2026-11-20) it is no longer updated: the agents' notifications and the Grafana deploy panels are the record.

## IaC Security Scanning

`iac-security.yml` runs Checkov from a pinned PyPI version in a separate, no-secrets workflow. The scan is currently soft-fail so first-run findings can be reviewed and suppressed or fixed without blocking unrelated infrastructure work. After the baseline is clean, switch from `--soft-fail` to severity-based hard failures.

KICS remains a useful secondary scanner, but the Checkmarx GitHub Action and Docker distribution should not be used in this secret-bearing deploy workflow until the supply-chain situation has been reviewed and a trusted, pinned release path is chosen.

## Security Features

- **No host access from CI**: workflows only write signed requests to `deploy/<host>`; the hosts pull them
- **No fleet-wide secret**: hiera-eyaml, per-host PKCS7 keypairs - a compromised CI runner never holds a key that unlocks more than one host's data
- **CrowdSec enforcement**: `mljr` installs the nftables firewall bouncer for host-level remediation

## Troubleshooting

### Request created, nothing applied
- Check the host's agent: `journalctl -u deploy-agent` (ugreen keeps no journal: see `/var/lib/node-textfile/homelab_deploy.prom`)
- docs/DEPLOY_AGENT.md, "Failure modes"

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
# pinned to one build:
gh api repos/:owner/:repo/dispatches -f event_type=service-update -f 'client_payload[service]=homepage' -f 'client_payload[tag]=sha-1a2b3c4'
```
