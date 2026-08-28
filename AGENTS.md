# AGENTS.md

Guidance for coding agents working in this repository. For architecture,
features, and full command reference see [`README.md`](README.md) — this
file covers conventions and gotchas an agent needs but wouldn't get from
reading the code alone.

## What this repo is

Masterless OpenVox (a Puppet fork) automation for the `mljr.eu` homelab.
Each agent-managed host (`mljr`, `nuc`, `ugreen`) runs `puppet apply`
locally against its own rsynced copy of `openvox/` — no puppetserver,
no PuppetDB, no cross-host catalog sharing. `nas` (Unraid, tmpfs root) and
`wd_mycloud` (busybox) have no agent at all; every mutating action against
them is a proxy `exec` declared on **nuc's own node block**, reached over
SSH from nuc at apply time.

`ansible/` is the fully-superseded previous implementation (cut over
2026-08-23). It is not deployed by CI, not documented as a supported path,
and should not be edited except to consult `git log` on a role directory
when porting behavior that isn't yet reflected in `openvox/`. Do not "fix"
anything in `ansible/` — treat it as a frozen reference.

## Before making a change

```bash
git config core.hooksPath .githooks   # once, if not already set
make test                              # service-catalog validation + compose YAML lint
```

There is no `puppet parser validate` wired into CI — a manifest syntax
error is only ever caught live on the first `openvox-sync.sh noop` against
a real host. Run `make openvox-check-<host>` before `openvox-deploy-<host>`
for anything touching `openvox/manifests` or `openvox/modules`.

If you touch a generic service's deployable files under `services/<name>/`,
run `make sync-openvox-services` — the OpenVox tree keeps its own vendored
copy and CI rejects drift between the two.

## Conventions that aren't obvious from the code

**`managed:false` vs `skip_deploy:true`** (both are `services_catalog`
flags, both mean "don't deploy the normal way", but they are not
interchangeable):
- `managed:false` — a container someone set up by hand (e.g. Unraid UI).
  Nothing ever deploys it; catalog entry exists purely for
  health-report/backup-dashboard visibility.
- `skip_deploy:true` — a dedicated class owns deployment (`authelia`,
  `glance`, `mailcow`). The entry is still "active on this host" for
  orphan-cleanup purposes.

**Real incident (2026-08-23):** `roles::services`' cleanup-orphaned exec
reused the deploy loop's filtered host-service list (which excludes
`skip_deploy` entries) as its "is this active" check, and deleted
`/opt/authelia` — a real, running service — on its first production apply.
Any class that re-filters `services_catalog` for a purpose other than
"should I deploy this" must re-derive its own filter (`host == this host
and enabled`, nothing else — see `$host_active_names` in
`openvox/manifests/services.pp`). Never reuse another class's
deploy-scoped list for a different purpose.

**The check/apply script-pair pattern.** A plain `exec`'s `command` does
*not* run under `puppet apply --noop` — but its `unless`/`onlyif` guard
*does*, for real, since Puppet needs the guard's exit code even in noop
mode. A guard with a mutating branch is therefore genuinely dangerous under
noop. Anywhere a guard would otherwise mutate (cleanup, provisioning,
keyring self-heal, etc.), split it into `<name>-check.sh` (read-only,
used as the guard) and `<name>-apply.sh` (the real mutating logic, only
reachable via the exec's `command`). See
`openvox/modules/roles/files/services_common/cleanup-check.sh` /
`cleanup-apply.sh` for the canonical example. Follow this pattern for any
new guarded exec.

**Secrets decrypt host-side, never centrally.** Every `vault_*` key in
`openvox/data/common.eyaml` is hiera-eyaml/PKCS7, resolved via
`lookup('vault_...')` on the host itself at apply time — there is no
central unlock point and CI needs no vault-password secret. Edit secrets
through a host that already has the key pair (see README's Secrets
Management section for the scp/eyaml-edit/scp-back flow); never attempt to
decrypt `common.eyaml` locally, there's no `eyaml` binary outside Puppet's
bundled Ruby.

**Staging is opt-in and explicit.** `staging: true` on a catalog entry plus
`services/<name>/dev/docker-compose.yml` is required; production applies
never start or recreate staging containers, and staging never runs a
production `post-deploy.sh`.

## Key files

| File | Purpose |
|------|---------|
| `openvox/manifests/site.pp` | Entrypoint — one node block per agent-managed host |
| `openvox/data/common.yaml` | `services_catalog` + global config |
| `openvox/data/common.eyaml` | Encrypted `vault_*` secrets |
| `openvox/modules/roles/manifests/*.pp` | One class per role |
| `services/<name>/docker-compose.yml` | Canonical service Compose definitions |
| `scripts/openvox-sync.sh` | rsync manifests to a host + run `puppet apply` |
| `tools/cmd/` | Go tools (service validation, healthreport, backup-dashboard, etc.) |

## Adding a service

1. Add to `services_catalog` in `openvox/data/common.yaml`.
2. Create `services/<name>/docker-compose.yml`.
3. Secrets needed? Add `vault_*` keys to `common.eyaml`, then map them into
   the service's `.env` in `roles::services`' `$all_secrets` hash
   (`services_nas.pp` instead, for a `nas`-hosted service).
4. Staging needed? Add `services/<name>/dev/docker-compose.yml` and set
   `staging: true`.
5. `make test`, then `make openvox-check-<host>` before a real deploy.

## Full reference

Architecture diagram, monitoring stack details, GitHub Actions workflow
behavior, and the complete command list live in [`README.md`](README.md).
`openvox/README.md` covers internal OpenVox-specific conventions
(masterless model, hiera hierarchy, EPP templates, Forge module pinning)
in more depth than this file does.
