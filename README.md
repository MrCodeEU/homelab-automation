# Homelab Automation

OpenVox (a Puppet fork) automation for deploying and managing self-hosted
services across the `mljr.eu` homelab over Tailscale. Masterless: every host
runs `puppet apply` against its own locally-synced copy of the manifests —
there is no puppetserver/PuppetDB anywhere in this fleet.

`ansible/`, the previous implementation of this exact same automation
(superseded 2026-08-23), was removed 2026-09-02 after a full parity audit
confirmed every role had a real OpenVox equivalent. See
[Migrating from Ansible](#migrating-from-ansible) if you're looking for
what changed, or check out a commit before that date for the old tree.

## Quick Start

```bash
git clone https://github.com/MrCodeEU/homelab-automation.git
cd homelab-automation
git config core.hooksPath .githooks

# Puppet/eyaml decrypt keys are unique per host. See Secrets Management for
# bootstrap and disaster recovery; local dependencies are ssh/rsync/scp.

# Dry run — syncs manifests to every agent-managed host and runs
# `puppet apply --noop`, no changes made
make openvox-check
```

## Architecture

```
GitHub Actions / local openvox-sync.sh
             |
        Tailscale VPN (SSH, keyless via Tailscale ACLs)
             |
   +---------+---------+---------+---------+
   |                   |         |         |
 mljr                nuc       nas       ugreen
 VPS                 compute   Unraid    Debian NAS (UGOS)
 Caddy ingress       node      NAS       backup target,
 CrowdSec            Grafana,  proxy-    light read-only
                      Netronome exec'd   monitoring only
                                from nuc
```

`mljr`, `nuc`, and `ugreen` run a real Puppet agent and are synced +
applied directly (`scripts/openvox-sync.sh <host> [noop|apply]`). `nas`
(Unraid, tmpfs root) and `wd_mycloud` (busybox, no package manager) have
no agent at all — every mutating action against them is a proxy-exec
declared on `nuc`'s own node block in `openvox/manifests/site.pp`
(`roles::services_nas`, `roles::unraid_proxy`, `roles::wd_mycloud_proxy`,
etc.), reached over SSH from nuc rather than by installing anything on
the appliance itself.

NAS/Unraid services are mostly managed manually and only proxied or monitored where explicitly configured. `ugreen` is not a general deployment target for `roles/base`, but does run some Docker services (oxicloud, smartctl-exporter, syncthing-ugreen) plus host-facts-endpoint, Grafana Alloy, iperf3, and the SFTP backup target. During Ugreen storage recovery, set `role::ugreen::backup_remote_target_enabled: false` in its node data to pause management of that write path without deleting its existing contents.

Two more hosts sit outside the diagram above: `wd_mycloud` (WD My Cloud EX2 Ultra - busybox, no Docker, backup-target-only; gets Tailscale and node_exporter as bare binaries with a boot-hook persistence mechanism, see AGENTS.md) and `homeassistant` (its own HAOS appliance, `proxy_only` - Caddy front door plus a remote Prometheus scrape only, no agent runs there).

## Features

- Idempotent, masterless Puppet (OpenVox) deployments — `puppet apply` runs
  locally on each target host, no central Puppet server anywhere.
- Generic Docker Compose service deployment from `services/<name>/docker-compose.yml`,
  data-driven from one `services_catalog` list (`openvox/data/common.yaml`)
  via a single `roles::services::service` defined type — not ~30 hand-unrolled
  resource blocks. `services/` is canonical; deployable assets are checked
  against OpenVox's required vendored copy on every test run.
- Automatic Caddy HTTPS and reverse proxy snippets.
- Staging deployments through `services/<name>/dev/docker-compose.yml`
  (catalog entries with `staging: true` deploy explicitly to `nuc`).
- Cleanup of disabled or moved services to avoid stale containers and Caddy snippets.
- Weekly Docker image/container pruning + gated reboot during the scheduled
  CI run only (`FACTER_openvox_weekly_maintenance`, see `openvox/manifests/site.pp`).
- Grafana/Loki/VictoriaMetrics monitoring with Grafana Alloy agents (mljr, nuc, ugreen, nas) plus bare node_exporter + remote scraping for hosts that can't run Alloy (wd_mycloud, Home Assistant). SMART, systemd, and btrfs collectors included where applicable.
- CrowdSec security engine with nftables firewall enforcement on `mljr`.
- Netronome network testing on `nuc`, exposed as `speedtest.mljr.eu`.
- GitHub Actions deployment over Tailscale — secrets decrypt host-side via
  hiera-eyaml at apply time, so CI itself needs no vault-password secret.
- Local deployment via `make openvox-check`/`openvox-deploy` (and per-host
  variants) — no GitHub Actions required.

## Directory Structure

```
homelab-automation/
├── AGENTS.md                         # Agent/operator guidance
├── openvox/
│   ├── manifests/site.pp             # Entrypoint - one node block per agent-managed host
│   ├── hiera.yaml                    # Hiera hierarchy (node/common data -> host secrets)
│   ├── data/
│   │   ├── common.yaml               # Service catalog (services_catalog) + global config
│   │   └── secrets/                  # per-host hiera-eyaml encrypted vault_* values
│   ├── keys/                         # per-host public keys; private keys are gitignored
│   └── modules/roles/
│       ├── manifests/                # One class per role: base, caddy, services,
│       │                             # services_nas, backup, authelia, mailcow, glance,
│       │                             # grafana_alloy, healthreport, crowdsec_firewall_bouncer,
│       │                             # host_facts_endpoint, unraid_proxy, wd_mycloud_proxy, ...
│       ├── templates/                # EPP templates (Puppet's native templating)
│       └── files/                    # Vendored per-service content + check/apply script pairs
├── services/
│   ├── crowdsec/
│   ├── grafana/
│   ├── speedtest/                    # Netronome
│   └── ...
└── .github/workflows/
    └── deploy.yml
```

## Service Configuration

Services are defined under `services_catalog` in `openvox/data/common.yaml`:

```yaml
services_catalog:
  - name: myservice
    enabled: true
    domain: "myservice.mljr.eu"
    port: 8080
    host: nuc
    managed: true
    caddy_auth: "authelia"
```

Important options:

| Option | Description |
|--------|-------------|
| `enabled` | Whether the service should exist |
| `managed` | If false, this entry is documentation only (health-report/backup-dashboard visibility for a container someone set up by hand, e.g. through the Unraid UI) — no class deploys it |
| `skip_deploy` | A dedicated class owns deployment (e.g. `authelia`, `glance`, `mailcow`) — the entry still counts as "active on this host" for orphan-cleanup purposes, it's just not deployed by the generic `roles::services`/`roles::services_nas` loop |
| `domain` | String or list of domains |
| `port` | Backend port, or `0` for notification-only/no UI services |
| `host` | Which host owns this service |
| `caddy_auth` | `basicauth` or `authelia` |
| `staging` | Allows an explicit `<name>-staging` deployment to `nuc` |

Disabled services can remain in the catalog so orphan-cleanup can remove old
deployments and stale proxy snippets safely. **`managed:false` and
`skip_deploy:true` are not the same exclusion** — any class that filters
this catalog for a purpose other than "should I deploy this" (cleanup,
healthcheck enumeration, backup targeting) needs to re-derive its own
filter rather than reusing another class's deploy-scoped list; conflating
the two caused a real incident (see `roles::services`' own header comment
on `$host_active_names` in `openvox/modules/roles/manifests/services.pp`).

## Key Services

| Service | Host | Domain |
|---------|------|--------|
| Caddy | `mljr` | Public ingress for `*.mljr.eu` |
| Authelia | `mljr` | `auth.mljr.eu` |
| CrowdSec | `mljr` | `crowdsec.mljr.eu`, `security.mljr.eu` |
| Grafana | `nuc` | `monitor.mljr.eu`, `grafana.mljr.eu` |
| Netronome | `nuc` | `speedtest.mljr.eu` |

## Secrets Management

Secrets are stored per agent in `openvox/data/secrets/<certname>.eyaml`,
encrypted with [hiera-eyaml](https://github.com/voxpupuli/hiera-eyaml)
(PKCS7). Only ciphertext is committed. Each host has a distinct private key
under `/etc/puppetlabs/puppet/eyaml/hosts/<certname>/`; a compromised agent
therefore cannot decrypt another agent's file. Shared credentials are
intentionally re-encrypted separately for every host that needs them.

There's no `eyaml` binary on a plain dev machine — it only exists inside
Puppet's bundled Ruby (`/opt/puppetlabs/puppet/bin/eyaml`). Bootstrap a new
host key with `scripts/bootstrap-openvox-eyaml-host-key.sh <host>`; it creates
the private key on that host and retrieves only its public key. Edit a host's
file through that same host:

```bash
scp openvox/data/secrets/nuc.tail33930.ts.net.eyaml root@nuc.tail33930.ts.net:/tmp/nuc.eyaml
ssh root@nuc.tail33930.ts.net "/opt/puppetlabs/puppet/bin/eyaml edit /tmp/nuc.eyaml \
  --pkcs7-public-key=/etc/puppetlabs/puppet/eyaml/hosts/nuc.tail33930.ts.net/public_key.pkcs7.pem \
  --pkcs7-private-key=/etc/puppetlabs/puppet/eyaml/hosts/nuc.tail33930.ts.net/private_key.pkcs7.pem"
scp root@nuc.tail33930.ts.net:/tmp/nuc.eyaml openvox/data/secrets/nuc.tail33930.ts.net.eyaml
ssh root@nuc.tail33930.ts.net "shred -u /tmp/nuc.eyaml"
```

**Decryption happens host-side**, never in CI. The per-host private keys are
gitignored; only public keys and ciphertext are committed. This is why **CI
needs no vault-password secret at all**.

Tailscale OAuth secrets (`TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`) still stay
as GitHub secrets, since they're used by the Tailscale GitHub Action
directly, unrelated to hiera-eyaml.

The pre-commit hook rejects any staged eyaml file containing plaintext.

### Adding or changing a secret

1. Identify every host that needs the value. A shared value is duplicated as
   distinct ciphertext in each recipient file; a service selectable for NUC
   staging also makes NUC a recipient.
2. Add the `vault_*` lookup to the owning role or the appropriate host branch
   of `roles::services`; an encrypted value alone is not injected into a
   service.
3. Edit each recipient's file using that same host's keypair as shown above.
   Never transfer a private key between hosts or print plaintext in a shell
   command/log.
4. Commit only ciphertext, open a PR, and let its live noops validate every
   recipient before deployment.

### Key backup and host recovery

Keep one offline/Bitwarden backup of every host-specific private key, labelled
with its certificate name. On recovery, restore the **exact existing** key to
`/etc/puppetlabs/puppet/eyaml/hosts/<certname>/private_key.pkcs7.pem` with
mode `0400` and ownership `root:root`, restore the matching public key with
mode `0444`, install `hiera-eyaml` if necessary, then run the normal noop.

`scripts/bootstrap-openvox-eyaml-host-key.sh` is only for a genuinely new host:
it generates a new keypair and therefore cannot decrypt existing ciphertext.
Do not use it to recover a lost key; recover the original key from the backup
instead.

## Security

CrowdSec replaced fail2ban as the active security stack.

- Dockerized CrowdSec runs on `mljr`.
- The web UI is exposed through Caddy and protected with Authelia.
- `crowdsec-firewall-bouncer-nftables` is installed on `mljr` by `roles::crowdsec_firewall_bouncer` for host-level enforcement.
- Fail2ban is no longer managed by this repo.

## Monitoring

SigNoz has been replaced by a Grafana stack on `nuc`:

- Grafana UI
- VictoriaMetrics for metrics (PromQL-compatible, 10y retention; accepts Prometheus remote_write on host port 19090)
- Loki for logs
- Grafana Alloy agents on Rocky hosts, `ugreen`, and `nas` (via `services/nas-alloy/`, not the templated role - see AGENTS.md)

Alloy collects host metrics (including systemd failed-unit state and btrfs pool health), Docker metrics, Docker logs, Caddy logs, and CrowdSec metrics. Hosts that can't run Alloy at all (`wd_mycloud` - no 32-bit ARM build exists; Home Assistant - not a Docker host) get bare `node_exporter`/native Prometheus endpoints remote-scraped from nuc's Alloy instead. SMART data comes from a separate `smartctl-exporter` service on every host with real disks (not mljr - VPS, no real SMART data; not wd_mycloud - no Docker).

Grafana provisioning is stored in `services/grafana/`:

- Datasources: `services/grafana/provisioning/datasources/datasources.yml`
- Dashboard provider: `services/grafana/provisioning/dashboards/dashboards.yml`
- Dashboards: `services/grafana/dashboards/*.json` (overview, security, storage, homeassistant)

Once a host sends metrics/logs with matching `instance`/`host` labels, the provisioned dashboards include it automatically via the `$host` template variable.

## Staging

Set `staging: true` on a catalog entry in `openvox/data/common.yaml` and add
`services/<name>/dev/docker-compose.yml` to make a service staging-capable.
Staging is deliberately explicit: normal production applies do not start or
recreate staging containers. Deploy one or more staging services on `nuc` with
either `make openvox-staging SERVICE=homepage,speedtest` or the **Deploy
Homelab** workflow's `staging_services` input. The requested names must be
enabled, managed catalog entries with `staging: true`.

Staging receives the existing `<service>.dev.mljr.eu` Caddy route and a
non-blocking health probe on production port + 10000. It never runs a
production post-deploy hook, so it cannot register or mutate shared external
state by accident.

## Validation

From the repository root:

```bash
make test
```

When changing a generic service's deployable files, update the OpenVox copy
with `make sync-openvox-services`; the pre-commit hook and CI reject drift.

Runs service-catalog validation (`.githooks/pre-commit`) and Caddy
template rendering — both engine-independent, since they validate
`services/` and the shared `services_catalog` data, not Puppet machinery.
`_check-syntax` runs `puppet parser validate` against every OpenVox
manifest when a `puppet`/`openvox` binary is available locally (it isn't
on a plain dev machine, so this step is a SKIP there); CI's
`openvox-pr-check.yml` runs it for real, plus a live noop apply against
production, on every PR. `_check-compose` validates every service's
`docker-compose.yml`.

## Common Commands

```bash
# Dry run — syncs manifests + runs `puppet apply --noop` on every
# agent-managed host, no changes made
make openvox-check

# Full deploy (real apply)
make openvox-deploy

# Single host
make openvox-check-mljr
make openvox-deploy-nuc
make openvox-check-ugreen

# Or drive scripts/openvox-sync.sh directly for anything not covered above
./scripts/openvox-sync.sh mljr.tail33930.ts.net noop
./scripts/openvox-sync.sh nuc.tail33930.ts.net apply
```

Both `make openvox-check`/`openvox-deploy` run all 3 hosts in parallel and
print a final `==> fleet summary` line per host; every line of remote
output is also prefixed with the host's short label (`[mljr]`, `[nuc]`,
`[ugreen]`) so a multi-host run stays readable, and a full raw log is
saved under `logs/openvox/<host>-<mode>-<timestamp>.log` for later
inspection.

## GitHub Actions

Pull requests are handled by `.github/workflows/openvox-pr-check.yml`.
`.github/workflows/deploy.yml` handles manual dispatch, the weekly schedule,
and repository dispatch from external repositories, calling
`scripts/openvox-sync.sh` directly, no Ansible tooling involved. Needs no
vault-password secret (see Secrets Management above); only
`TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET` for Tailscale.

The PR workflow first validates OpenVox/EPP/shell syntax offline. Its live
production noop is restricted to same-repository PRs authored by `MrCodeEU`,
uses the `production-check` GitHub environment, and syncs proposed code into a
per-run `/tmp/openvox-pr-*` environment that is removed afterward. Configure
`production-check` protection in GitHub before making this check required.

External repos can trigger a specific service deployment with `repository_dispatch`. The workflow resolves the service's host from `services_catalog` and applies that host's full catalog (+ `mljr` too, for the Caddy snippet) — Puppet's whole-catalog apply is idempotent enough that there's no surgical single-service fast path to target separately, unlike the old Ansible pipeline's `environment` field:

```yaml
- name: Trigger deployment
  run: |
    curl -X POST \
      -H "Authorization: token ${{ secrets.DISPATCH_TOKEN }}" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/MrCodeEU/homelab-automation/dispatches \
      -d '{
        "event_type": "service-update",
        "client_payload": {
          "service": "homepage",
          "commit_sha": "${{ github.sha }}"
        }
      }'
```

## Adding a Service

1. Add the service to `services_catalog` in `openvox/data/common.yaml`.
2. Create `services/<name>/docker-compose.yml`.
3. If the service needs secrets: add `vault_*` keys to the encrypted file for
   every host that needs the service under `openvox/data/secrets/`
   (see Secrets Management above), then add a per-service block to
   `roles::services`' own `$all_secrets` hash in
   `openvox/modules/roles/manifests/services.pp` (or `services_nas.pp` for
   a `nas`-hosted service) mapping them into the service's `.env`.
4. Add `services/<name>/dev/docker-compose.yml` and set `staging: true` in
   the catalog entry if staging is needed.
5. Run `make test`, then `make openvox-check-<host>` before a real
   `openvox-deploy-<host>`.

## Migrating from Ansible

`ansible/` was the primary implementation of this automation until
2026-08-23, when it was fully superseded by the OpenVox port above (all 26
roles ported 1:1, verified live against real production infrastructure
role-by-role before the CI cutover). It was kept as a short-lived
reference afterward, then removed 2026-09-02 following a full parity
audit that confirmed every role had a real OpenVox equivalent - one gap
was found (`mailcow_auto_update`'s default; kept intentionally on rather
than restored) and one unrelated gap the audit surfaced along the way
(canarytokens missing backup coverage) was fixed separately.

If you're looking for the old `ansible-playbook`/`ansible-vault`/
`make deploy-*` workflow: check out any commit before 2026-09-02 and the
whole `ansible/` tree is there. `git log --diff-filter=D -- ansible/` (or
`git log --oneline -- ansible/roles/<name>/`) is the most reliable way to
find when a given role was removed and see what it used to do before its
Puppet port.

## License

MIT License
