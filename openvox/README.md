# openvox/

Masterless OpenVox (Puppet fork) manifests — the real production deploy
mechanism for this repo (see the root `README.md` for the user-facing
overview and `make openvox-*` commands). This file covers the internal
conventions worth knowing before touching anything in here.

## Roles and profiles

`manifests/site.pp` node blocks are one-liners (`include role::mljr`, etc).
The `role` module (`modules/role/manifests/<host>.pp`) has one class per
node archetype, each just listing which `roles::*` classes apply plus any
genuinely node-specific one-off resources (e.g. nuc's Netronome firewall
port). `roles::*` (the pre-existing module) is this repo's technology tier
- hand-rolled, site-specific classes, already the equivalent of a
"profile" in the standard Puppet roles/profiles pattern. There's
deliberately no separate `profile::*` module: it would 1:1-wrap `roles::*`
with no grouping value at this scale (3 hosts, not a fleet) - see
`docs/OPENVOX_BACKLOG.md` for the fuller reasoning.

Per-host variance that used to be literal `class { 'roles::x': param =>
value }` arguments in `site.pp` now lives in
`data/nodes/<certname>.yaml`, bound automatically by Puppet's
class-parameter hiera lookup - every `roles::*` class is declared via
plain `include`, never `class { }`. `hiera.yaml`'s per-node hierarchy
level (`nodes/%{trusted.certname}.yaml`) is checked before `common.yaml`.

Since `role` is a second local module alongside `roles`,
`scripts/openvox-sync.sh` syncs both (`modules/role/` and
`modules/roles/`) and `openvox-pr-check.yml`'s `puppet parser validate`
covers both.

## Masterless model

There is no puppetserver/PuppetDB. `scripts/openvox-sync.sh <host> [noop|apply]`
rsyncs (scp on `ugreen`, see the script's own header) this whole directory
to `/etc/puppetlabs/code/environments/production/` on the target host, then
runs `puppet apply` **locally on that host** against the synced copy. Every
host's compiler only ever sees its own node block in `manifests/site.pp` —
there's no cross-host catalog sharing, no `hostvars`-equivalent, no shared
compile step.

`nas` (Unraid, tmpfs root) and `wd_mycloud` (busybox) have no Puppet agent
at all. Every mutating action against them is an `exec` resource declared
on **nuc's own node block**, reached over SSH from nuc at apply time
(`roles::services_nas`, `roles::unraid_proxy`, `roles::unraid_backup_proxy`,
`roles::wd_mycloud_proxy`, `roles::wd_mycloud_node_exporter_proxy`,
`roles::unraid_host_facts_proxy`). This is why applying `nuc` is what
actually reaches `nas` — there's nothing to sync to nas itself.

## Data layer (hiera)

`hiera.yaml` defines a two-level hierarchy: `data/common.yaml` (plain YAML —
the `services_catalog`, global config like domains/timezones/hostnames) then
`data/common.eyaml` (hiera-eyaml encrypted, PKCS7 — every `vault_*` secret).
A class reads either the same way: `lookup('some_key')` or
`lookup('vault_some_key')`.

**Decryption happens host-side**, not on the machine running
`openvox-sync.sh`. Every host that needs to resolve a `vault_*` value has
its own copy of the PKCS7 key pair under `/etc/puppetlabs/puppet/eyaml/`,
deployed once via `scripts/install-openvox-eyaml.sh <host>` — a deliberately
separate step from the general environment sync, since not every host needs
every secret and there's no puppetserver to act as a single unlock point.
`keys/private_key.pkcs7.pem` is gitignored; only the public key is ever
committed.

## Templates

EPP (`.epp`), Puppet's own native templating — not ERB, not Jinja2. Used
for `.env` rendering (`modules/roles/templates/services/env.epp`) and
anywhere else per-service/per-host values need to land in a rendered file.

## The check/apply script-pair convention

A plain `exec` resource's own `command` does **not** actually run under
`puppet apply --noop` — confirmed empirically (see the migration's own
memory notes). What Puppet *does* evaluate for real even under `--noop` is
an `unless`/`onlyif` **guard** command, since Puppet needs its real exit
code to decide whether the exec is even applicable.

This means a guard script with a mutating branch is genuinely dangerous
under noop, even though the exec's main command is safe. Anywhere this
migration needs a guard that would otherwise mutate (cleanup, provisioning,
locked-keyring self-heal, etc.), the logic is split into two files:

- `<name>-check.sh` — read-only, used as the `unless`/`onlyif` guard. Exits
  0 ("nothing to do") or non-zero ("orphan/drift detected, run apply").
- `<name>-apply.sh` — the real mutating logic, only reachable via the
  `command` of an exec whose `unless` is the check script.

See `modules/roles/files/services_common/cleanup-check.sh` /
`cleanup-apply.sh` for the canonical example.

## `managed:false` vs `skip_deploy:true` — not the same exclusion

Both are catalog-entry flags on `services_catalog`, and both mean "don't
deploy this the normal way," but they mean different things to different
consumers:

- `managed:false` — a real container someone set up by hand (e.g. through
  the Unraid UI). No class deploys it, ever. Purely catalog documentation
  for health-report/backup-dashboard visibility.
- `skip_deploy:true` — a dedicated class owns deployment instead (e.g.
  `authelia`, `glance`, `mailcow` each have their own class). The entry is
  still "active on this host" for **orphan-cleanup** purposes — cleanup
  must not treat it as gone just because it's absent from the generic
  services deploy loop.

**Real incident, 2026-08-23**: `roles::services`' cleanup-orphaned exec
reused the deploy-loop's own filtered host-service list (which excludes
`skip_deploy` entries) as its "is this active" check, and deleted
`/opt/authelia` (a real, running, `skip_deploy:true` service) on its first
production apply. Fixed by giving cleanup its own filter matching Ansible's
original semantics exactly (`host == this host and enabled`, nothing else)
— see `$host_active_names` in `manifests/services.pp`. **Any class that
re-filters `services_catalog` for a purpose other than "should I deploy
this" must re-derive its own filter, never reuse another class's
deploy-scoped list.**

## Releases and rollback

A real apply (`make openvox-deploy-<host>` / `openvox-recovery`) no longer
overwrites `production` in place. `scripts/openvox-sync.sh` syncs into a new
`releases/<timestamp>/` directory on the host, then atomically swaps the
`production` symlink to point at it (`ln -sfn` into a temp name, `mv -Tf`
over `production` - never a briefly-missing or partial `production`). The
last `OPENVOX_RELEASE_KEEP` releases (default 5) are kept; older ones are
pruned after each swap. Noop runs and isolated PR-check environments are
unaffected - they still sync straight into their target directory, since
they never mutate what's actually running.

`scripts/openvox-rollback.sh <host> [steps-back]` points `production` back
at an older release and re-applies, undoing a bad catalog without
re-syncing anything (`make openvox-rollback HOST=<host> [STEPS=n]`). It
rolls back manifests/hiera/data (the catalog), not service data - a bad
apply that already changed running service state needs `restore.sh`
separately, same as any other recovery.

Forge modules (`Puppetfile`) are pinned by version, not by release, so they
live in a persistent shared dir - `environments/vendor-modules` - instead
of inside each release. Rolling back swaps `roles` (this repo's own code,
inside the release) but deliberately leaves Forge module versions as
currently reconciled; if a rollback needs to cross a Puppetfile version
bump too, reconcile that manually first.

## Forge module dependencies

`Puppetfile` pins every direct and transitive Forge module. Do not install
modules manually: `scripts/openvox-modules.sh` verifies production during a
noop, reconciles it before an apply, and installs candidate versions into the
isolated PR environment for the live noop.

Dependabot does not support Puppetfiles. `renovate.json` configures Renovate's
native Puppet manager to open grouped, non-automerge update PRs after a
seven-day release delay. The Renovate GitHub App must be enabled for this
repository once; the PR checks then validate dependency compatibility and the
owner-authored PRs additionally validate the resulting production catalog in
an isolated live noop. Renovate PRs never receive the production-check secrets.

## Catalog unit tests

`make test-openvox-unit` compiles the seed `rspec-puppet` catalog tests in a
pinned VoxBox image containing OpenVox 8.28.1. It has no host, Tailscale, or
secret access. The test fixture downloads the same pinned `puppetlabs/stdlib`
version as `Puppetfile` into ignored `openvox/spec/fixtures/`; CI runs this
target for every OpenVox PR before the owner-only live noop.
