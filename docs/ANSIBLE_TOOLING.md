# Ansible Tooling

## Enabled

### ARA Records Ansible

Deployments install ARA into the same `ansible-core` pipx environment as Ansible and enable the ARA callback plugin in offline mode. The callback records playbook results into a SQLite database and uploads the database plus simple JSON exports as a GitHub Actions artifact.

Artifact name:

```text
ara-report-<github run id>
```

Local inspection:

```bash
pip install "ara[server]"
ARA_DATABASE=sqlite:////path/to/artifact/ara/ansible.sqlite ara playbook list
ARA_DATABASE=sqlite:////path/to/artifact/ara/ansible.sqlite ara host list
```

### Static Ansible Map

The repository includes a lightweight visualizer:

```bash
make docs-ansible-map
```

It reads `ansible/inventory/hosts.yml` and `ansible/inventory/group_vars/all/all.yml`, then writes `docs/ansible-map.md` with Mermaid diagrams for inventory structure and service placement.

### Checkov IaC Scan

`.github/workflows/iac-security.yml` runs Checkov in a separate workflow with read-only repository access and no production deployment secrets. It scans Ansible, GitHub Actions, Dockerfiles, Docker Compose files, and other IaC that Checkov recognizes, then uploads both a workflow artifact and SARIF results when GitHub code scanning accepts the upload.

The scan is intentionally soft-fail at first. Use the first few runs to review findings, add narrow suppressions where the risk is accepted, and fix true positives. Once the baseline is clean, replace `--soft-fail` with severity-based hard failures.

## Deferred

### KICS

KICS is useful for Infrastructure-as-Code security scanning, but it should run outside the deployment workflow because that workflow has production secrets and Tailscale access. Recent public supply-chain reports have also called out Checkmarx/KICS GitHub Action and Docker distribution paths, so do not add the official action or floating Docker image here without pinning and reviewing the artifact source.

Recommended shape when enabled:

- Separate workflow from deploy.
- No Ansible Vault password, Tailscale OAuth, or production secrets.
- Pinned KICS release artifact or another trusted scanner.
- SARIF upload only after reviewing first-run findings and suppressions.
