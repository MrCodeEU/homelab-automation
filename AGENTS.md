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

`ansible/`, the previous implementation (cut over to OpenVox 2026-08-23),
was removed 2026-09-02 after a full parity audit confirmed every role had
a real OpenVox equivalent. If you need to see the original behavior of a
role while porting something that isn't yet reflected in `openvox/`, check
out a commit before that date and read `ansible/roles/<name>/` there, or
`git log --diff-filter=D -- ansible/roles/<name>/` to find when it was
removed.

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

**Secrets are host-scoped and decrypt host-side.** Every `vault_*` key is
hiera-eyaml/PKCS7 ciphertext in
`openvox/data/secrets/<certname>.eyaml`, resolved through `lookup('vault_...')`
on that host only. The matching private key lives at
`/etc/puppetlabs/puppet/eyaml/hosts/<certname>/private_key.pkcs7.pem`; only
the public key is committed. There is no central unlock point and CI needs no
vault-password secret.

When adding a secret, identify every recipient first. Put separately
encrypted copies in every recipient host file; include `nuc` when it can run
the service as an explicit staging deployment. Add the `lookup()` mapping in
the relevant role as well—an eyaml entry alone never reaches a container.
Edit a recipient file only through that recipient host's bundled `eyaml`
binary, copy back ciphertext only, and submit it through the normal PR/noop
path. Never print plaintext, commit a private key, or decrypt a host file on
another host.

`bootstrap-openvox-eyaml-host-key.sh` creates a *new* keypair and is for a
new host only. It cannot recover existing ciphertext. Disaster recovery must
restore that host's exact private key from the owner's offline backup before
the first apply. Do not delete or rotate a key without a verified backup and
a re-encryption plan.

**Staging is opt-in and explicit.** `staging: true` on a catalog entry plus
`services/<name>/dev/docker-compose.yml` is required; production applies
never start or recreate staging containers, and staging never runs a
production `post-deploy.sh`.

## Key files

| File | Purpose |
|------|---------|
| `openvox/manifests/site.pp` | Entrypoint — one node block per agent-managed host |
| `openvox/data/common.yaml` | `services_catalog` + global config |
| `openvox/data/secrets/<certname>.eyaml` | Per-host encrypted `vault_*` secrets |
| `openvox/modules/roles/manifests/*.pp` | One class per role |
| `services/<name>/docker-compose.yml` | Canonical service Compose definitions |
| `scripts/openvox-sync.sh` | rsync manifests to a host + run `puppet apply` |
| `tools/cmd/` | Go tools (service validation, healthreport, backup-dashboard, etc.) |

## Adding a service

1. Add to `services_catalog` in `openvox/data/common.yaml`.
2. Create `services/<name>/docker-compose.yml`.
3. Secrets needed? Add each `vault_*` key to every required host's
   `data/secrets/<certname>.eyaml`, encrypted with that host's public key;
   then map it into the service's `.env` in `roles::services`' host branch
   (`services_nas.pp` instead, for a `nas`-hosted service). Include `nuc`
   for any service selectable as staging there.
4. Staging needed? Add `services/<name>/dev/docker-compose.yml` and set
   `staging: true`.
5. `make test`, then `make openvox-check-<host>` before a real deploy.

## Full reference

Architecture diagram, monitoring stack details, GitHub Actions workflow
behavior, and the complete command list live in [`README.md`](README.md).
`openvox/README.md` covers internal OpenVox-specific conventions
(masterless model, hiera hierarchy, EPP templates, Forge module pinning)
in more depth than this file does.
