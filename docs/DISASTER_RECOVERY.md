# Disaster Recovery Runbook

What it actually takes to get this homelab back from a dead/corrupted/
reinstalled host, host-by-host, and an honest list of what is **not**
covered today. Originally written from a real audit (2026-08-13);
updated 2026-08-29 to reflect OpenVox as the real production deploy
mechanism since 2026-08-23 (see `openvox/README.md`) - every gap below
was verified against the actual role/catalog code, not assumed.

`ansible/` is still kept in the repo as reference for a few weeks (per
standing instruction). Every recovery step below goes entirely through
OpenVox now - the three roles that looked unported by name
(`syncthing-nas-key`, `unraid-bootstrap`, `wd-mycloud-tailscale`) turned
out to already be covered under different class names
(`roles::unraid_proxy`, `roles::wd_mycloud_proxy`, a static vault
secret) - see `docs/OPENVOX_BACKLOG.md` for the full correction.

Not yet tested against a real from-scratch rebuild (no spare hardware to
throwaway-test against). Treat the steps below as the best current
understanding, not a proven drill. A real test (spin up a VM, run this
doc against it) is its own backlog item.

## Before any of this works at all

Nothing in this repo can turn a bare OS install into an OpenVox-
controllable host by itself. These are manual, one-time, outside-Git
prerequisites:

1. **Install the base OS.** Rocky Linux for `mljr`/`nuc`. Unraid/UGOS/WD
   firmware are vendor images, reinstalled from their own recovery media
   (see host-specific sections below).
2. **Enroll the host into Tailscale interactively**, with `tailscale up
   --ssh`. There is no Tailscale-install role for `mljr`/`nuc` in this
   repo - both hosts are assumed already enrolled. SSH access to every
   managed host is Tailscale SSH, not a repo-tracked keypair
   (`.github/workflows/README.md`: *"No SSH keys in repository: Uses
   Tailscale authentication"*). Whoever does this needs access to the
   Tailscale admin console to approve the new device and confirm it has
   the right ACL tags.
3. **Install OpenVox itself** on the target host (`scripts/install-openvox.sh`
   handles the Rocky package install; Ugreen's Debian bootstrap is specified
   in its host section below). See `openvox/README.md` for the masterless
   model this repo relies on - no puppetserver, no PuppetDB, every host
   applies its own copy of `manifests/site.pp` locally.
4. **Deploy the eyaml decrypt key pair to the host**:
   `./scripts/install-openvox-eyaml.sh <host>`. This scp's
   `openvox/keys/private_key.pkcs7.pem` (gitignored, **not** a GitHub
   Actions secret - see below) to `/etc/puppetlabs/puppet/eyaml/` on the
   target and installs the `hiera-eyaml` gem. Without this step, any
   class that does `lookup('vault_...')` fails outright - there's no
   puppetserver to fall back on for decryption.
5. **Sync the environment and apply**: `make openvox-deploy-<host>` (or
   `make openvox-check-<host>` first, to noop it) runs
   `scripts/openvox-sync.sh`, which rsyncs (scp for `ugreen`) the whole
   `openvox/` tree to `/etc/puppetlabs/code/environments/production/` on
   the target, then runs `puppet apply` locally there.
6. **`git config core.hooksPath .githooks`** - repo-standard pre-commit
   hooks, unrelated to any specific host.

**The eyaml private key is the single point of failure for every
`vault_*` secret in this repo, and it lives nowhere in Git.** If
`openvox/keys/private_key.pkcs7.pem` is lost and no host still has a
copy under `/etc/puppetlabs/puppet/eyaml/`, `data/common.eyaml` becomes
permanently undecryptable - not merely inconvenient, actually
unrecoverable, since PKCS7 has no backdoor. **Confirm today that this
key file has an outside-Git backup** (password manager, offline copy -
this doc can't verify that for you) before treating anything else in
this runbook as trustworthy. This replaces the old Ansible-vault-password
requirement; there is no equivalent single CI secret for it, deliberately
(masterless design, no single unlock point - see `openvox/README.md`).

**GitHub Actions secrets** (only 2 now - the eyaml key is never a CI
secret, it's deployed straight to hosts): `TS_OAUTH_CLIENT_ID`,
`TS_OAUTH_SECRET`.

**The single biggest thing this repo cannot back up or reproduce**: the
Tailscale admin console configuration itself - ACLs, device tags, the
`tag:ci` OAuth client scope, and every node's one-time interactive login.
If that's gone, every host needs re-enrolling and re-approving by hand
before OpenVox can reach any of them.

## mljr (Rocky, production ingress)

Once Tailscale-enrolled, OpenVox-installed, and the eyaml key deployed
(steps above), `make openvox-deploy-mljr` (or the normal CI deploy path
via `.github/workflows/deploy.yml`) brings up: base packages/Docker/
firewalld, CrowdSec + nftables bouncer, Caddy (reverse proxy/ingress +
ACME TLS), Authelia (SSO), Mailcow, Glance, HetrixTools agent, and every
service-catalog entry scoped to `host: mljr`.

`roles::backup` then auto-restores every `backup_critical: true` service
on a detected fresh install (`.initialized` flag missing) - see the
explicit fresh-host recovery mode below (`make openvox-recovery`).
Non-critical services still get their data back if you run `restore.sh
--service <name>` manually.

**Known friction, not data loss:**
- Caddy's ACME/TLS certificate cache isn't backed up - Let's Encrypt just
  reissues automatically once Caddy is back up and DNS resolves, but
  that's a delay and eats into Let's Encrypt's rate limit if it happens
  often.
- DNS records for `mljr.eu` (SPF/DKIM/DMARC/MX for Mailcow, the A/AAAA
  records pointing at this host) live at whatever DNS provider is used -
  entirely outside this repo. Have that provider's access ready.
- Mailcow's DKIM keys and mail queue live in Docker volumes covered by
  backup (`vmail-vol-1`, `mysql-vol-1`) - reproducible from backup, but
  slow/tedious per the role's own comments.
- CrowdSec's central-API machine registration is re-registerable but
  tedious (per the role's own comment) - local decisions restore fine
  from backup, but the instance needs to re-enroll with CrowdSec's
  central API.

## nuc (Rocky, staging + misc services)

Same mechanism as mljr: `make openvox-deploy-nuc`. Covers TutaBridge CLI
(headless Tuta export), health-report agent, Hawser Docker agent, and
every service-catalog entry scoped to `host: nuc` (mail-archiver, umami,
forgejo, kuma, grafana, and the various demo/utility services).

**TutaBridge specifically** needs one extra thing beyond a plain deploy:
`roles::tutabridge_cli` handles gnome-keyring bootstrapping and the
first Tuta login automatically (drives an interactive login via
`expect`, since this account has no TOTP) - no manual step needed here
anymore, unlike Outlook's OAuth Device Code Flow (see mail-archiver
below), which does need a human to visit a URL once per Microsoft
account.

**Just fixed as part of this audit (2026-08-13):** `mail-archiver` was
flagged `backup_critical: true` in the service catalog but had zero
actual entry in `roles/backup/defaults/main.yml`'s `backup_service_configs`
- the flag was inert, and archived mail would have been permanently lost
on host loss. Added a real backup entry (Postgres dump + the Data
Protection Keys volume, which is what decrypts stored IMAP/OAuth
credentials at rest - losing that means every account has to be
re-added from scratch even if the mail data itself survived).

**Cross-cutting gap found while fixing that, now fixed**: `restore.sh.j2`
used to only restore raw files/volumes - it never re-imported a `.sql`
dump into a running Postgres. Added a `restore_post_hook` (mirrors the
existing `backup_post_hook` pattern) for all four pg_dump-backed
services (forgejo, mail-archiver, umami, nocturne) - `restore.sh
--service <name>` now waits for the DB container to be ready and pipes
the dump straight in.

**Recovery sequencing**: PostgreSQL dumps are imported only after the target
container is running. For a fresh OpenVox host rebuild, use the explicit
recovery mode before the normal service apply, for example:

```bash
make openvox-recovery HOST=nuc SERVICE=forgejo,umami
```

It refuses an initialized host, restores raw service data before Docker starts,
and deliberately leaves PostgreSQL volumes empty for dump-backed services; the
registered post-deploy hook imports the matching logical dump once PostgreSQL
is ready. This avoids restoring both a physical PostgreSQL volume and its SQL
dump into the same database.

For an already-running service, the targeted manual restore remains available
for the common case of restoring one service after loss or corruption.

## nas (Unraid)

**Unraid's boot flash drive is backed up** - `/boot` → pCloud daily,
`tier: critical`, per `roles::unraid_backup_proxy` (nas has no agent,
this runs on nuc over SSH - see `openvox/README.md`'s masterless
model). This is the single most important thing for Unraid recovery
(Unraid's own guidance): it holds every array/share/plugin/
Docker-template configuration and the license key. Recovery: boot from
a fresh flash drive image, restore this backup onto it, boot.

Also backed up (all `tier: critical`, pCloud + best-effort ugreen/WD
depending on entry): `Fotos/Fotos`, `Fotos/Videos`, `Fotos/Wichtiges
Scans Adressen`, `Fotos/Musik`, and the Nextcloud borg repository.

**11 of 15 nas-hosted catalog services are `managed: false`**
(Unraid-UI-owned containers, `roles::services_nas` only generates their
Caddy proxy snippet): `nas` (management UI), `immich`, `nextcloud`, `dockhand`,
`syncthing`, `filerun` (disabled), `test-ocis`, `stats` (disabled),
`projects` (Vikunja), `pairdrop` (disabled), `dawarich`. **None of these
have a recreation definition anywhere in this repo** - no XML templates,
no `docker run` commands, no compose files checked in. If the flash
drive backup is intact, Unraid's own Docker template store (saved
alongside the container's own settings) should recreate most of these
automatically on a flash restore - but this has never been verified
end-to-end, and if the flash backup is ALSO gone, someone has to
manually reconstruct 11 containers from memory.

**Corrected finding (first pass of this audit got this wrong - checked
live instead of only reading `unraid_backup_paths`)**: these services
are NOT actually uncovered. Unraid's own **AppData Backup plugin** runs
weekly (Sundays 05:00, confirmed via `/boot/config/plugins/appdata.backup/config.json`
and its cron entry) and covers `immich` (DB+config, thumbnails
excluded as regenerable), `Vikunja`, the whole `dawarich` container
group (app+Sidekiq+Postgres+Redis), `syncthing`'s own config, `dockhand`,
`ollama`, `SFTPGo`, and others - writing to `/mnt/user/backup/appdata/`
(~94GB as of this audit, 2 weekly snapshots kept locally by the plugin).
Separately, Immich's actual **photo library is not even stored in
appdata** - `docker inspect immich` confirms it mounts
`/mnt/user/Fotos/Fotos` as an external library (`/libraries`), which is
already in `unraid_backup_paths` at `tier: critical`. Immich's photos
were never at risk; the appdata/DB (albums, faces, users) was the actual
gap.

**The real, narrower gap, now fixed**: `/mnt/user/backup/appdata/` - the
plugin's own output - lived only on the same array it protects against,
so a total array/host loss (not just a corrupted container) would have
taken the local backup down with it. Added it to `unraid_backup_paths`
as `tier: critical` (mirrors whatever the plugin currently has on disk,
no separate retention logic needed on this side).

**Nextcloud AIO master-volume gap, fixed 2026-08-29:** its configuration
lives in the named Docker volume
`nextcloud_aio_mastercontainer`, not in `/mnt/user/appdata`. The AppData
Backup plugin now includes its physical path
`/mnt/fastpool/docker/volumes/nextcloud_aio_mastercontainer/_data/` as an
extra folder. A manual backup created `extra_files.tar`; a read-only
`tar -tf` validation confirmed it contains the AIO configuration and Borg
recovery metadata. That archive is included by the existing offsite
`appdata-backup` mirror on its next scheduled run. Keep this setting in
the Unraid plugin, not OpenVox: Unraid owns these UI-managed containers
and their local backup lifecycle.

**Syncthing content is intentionally covered by replication, not AppData
Backup.** `/mnt/user/Sync` is replicated between the main PC, laptop,
nas, and ugreen, so rebuilding Syncthing rehydrates a failed peer.
OpenVox also copies the nas folder to `pcloud:Sync`; its `rclone sync`
uses `--backup-dir pcloud:.deleted/sync/<date>`, retaining deleted or
overwritten data for 30 days. This meets 3-2-1 while those peers and
pCloud are healthy. It is not 3-2-1-1-0: there is no immutable/offline
copy and no end-to-end Sync recovery drill recorded.

### Flash restore checklist and safe validation

Do **not** test a real flash restore on the production NAS. It can alter
disk assignments, licensing, Docker state, and the live array. The real
drill belongs on a spare USB and, preferably, separate hardware or a
scheduled maintenance window.

The safe no-outage validation is to extract a copy of the saved flash
archive into a fresh temporary directory, inspect it, and compare it
with live `/boot`. It does not write to `/boot`, start Docker, or alter
the array. Check that it contains
`config/plugins/dockerMan/templates-user/*.xml`, compare those template
names/checksums with the live tree, and confirm the AppData snapshot
also contains the matching `my-*.xml` files. The 2026-08-29 audit
confirmed the live tree contains templates for the active UI-managed
applications (Immich, Nextcloud AIO, Dockhand, Syncthing, Vikunja, and
Dawarich) and their supporting containers.

For an actual recovery, restore the archived boot device to a **new** USB
with the Unraid USB Flash Creator, then boot that USB. Before starting
the array, review every disk assignment against a pre-failure record.
Once Docker is enabled, use Apps → Previous Apps to recreate containers
from the restored templates, restore the AppData Backup snapshot, and
restore Nextcloud AIO's `extra_files.tar` master-volume data before
starting the AIO stack. Verify application data mounts and health one
application at a time. Unraid documents that the boot device retains
Docker templates specifically to support this recreation workflow.

**Verified 2026-08-29:** the latest flash archive was extracted only into
a disposable `/tmp` directory and compared with live `/boot`. All 40
template files were present with identical contents (zero missing, extra,
or mismatched files). The temporary directory was removed afterward.

## ugreen (UGreen NAS, UGOS)

OpenVox-managed subset only: `syncthing-ugreen`, `oxicloud`
(explicitly an initial test, no backup), `smartctl-exporter`, plus
`roles::host_facts_endpoint`, `roles::grafana_alloy`, `roles::iperf3`,
`roles::ugreen_tailscale` (version-check only, UGOS itself isn't
`dnf`-managed by design), and `roles::backup_remote_target` (the SFTP
chroot other hosts push backups into). Unlike mljr/nuc, ugreen has no
`roles::base` - see `role::ugreen`'s own comment for why.

Everything else - UGOS's own storage pool layout (mdraid → LVM → btrfs),
network share definitions, UGOS app-store installs - is vendor-appliance
config living entirely outside this repo, deliberately (per the
inventory's own comments: no dnf, vendor A/B overlay root, same posture
as leaving Unraid's own OS layer unmanaged). Recovery for that layer is
whatever UGOS's own recovery/reset process provides - not something
OpenVox touches or could reproduce.

### Rebuild procedure

The 2026-07-31 filesystem failure was recovered by rebuilding on new
hardware. The repeatable boundary is deliberately clear:

1. **Rebuild storage in UGOS first.** Use the UGOS UI/recovery media to
   recreate the data pool before running any automation. The current
   verified layout is two 10.9-TB HDDs in `md1` (RAID1) → LVM → Btrfs,
   mounted at `/volume1`, with a separate two-NVMe RAID1 bcache tier
   (`md2`). Verify `/volume1` is writable. OpenVox must never create,
   repair, or format this vendor-managed layout.
2. **Restore connectivity.** Add the Debian 12 Tailscale package source,
   install Tailscale, then authenticate with `tailscale up --ssh`. Approve
   the device and its intended tags in the Tailscale admin console. This
   is the first remote-management path after a factory reset.
3. **Install OpenVox for Debian 12.** Add the OpenVox Debian 12 apt source
   (`https://apt.voxpupuli.org`, suite `debian12 openvox8`) and install the
   OpenVox agent. Set its certname to `ugreen.tail33930.ts.net`. The
   generic `scripts/install-openvox.sh` is Rocky-only; do not run it here.
4. **Install the eyaml key pair**, then sync and apply:

   ```bash
   ./scripts/install-openvox-eyaml.sh ugreen.tail33930.ts.net
   make openvox-check-ugreen
   make openvox-deploy-ugreen
   ```

   The apply recreates `/volume1/homelab`, the managed Compose services,
   `homelab-facts`, Grafana Alloy, iperf3/Netronome, the SFTP backup
   account and chroot (`/volume1/homelab-backups/data`), and the Btrfs
   backup-history timer. It deliberately does not manage a firewall on
   Ugreen; access is Tailscale-only.
5. **Repopulate the backup target from authoritative sources.** A rebuilt
   Ugreen is an empty *destination*, not a source of truth. Let the next
   backup runs from mljr/nuc/nas upload fresh data; do not try to make an
   incomplete old Ugreen copy authoritative. Its historical Btrfs
   snapshots are lost with the pool and start again after the first new
   backup.
6. **Verify before relying on it:** `tailscaled` and Docker are active,
   the expected containers are healthy, the SFTP target is writable by the
   restricted backup user, `homelab-backup-snapshot.timer` is enabled, and
   the next source backup completes to Ugreen. Confirm Grafana and the
   health report see the host again.

## wd_mycloud (WD MyCloud EX2 Ultra)

Only two proxy classes touch it, both run on nuc over SSH (wd_mycloud
has no agent - busybox, no libc match for any Puppet-family runtime):
`roles::wd_mycloud_proxy` and `roles::wd_mycloud_node_exporter_proxy`,
both bare ARM binaries on a persistent data partition with a boot-hook
(hijacked `clamAV/start.sh` - the one thing confirmed to survive/re-run
after a reboot on this BusyBox device, no systemd/cron persistence
otherwise). Full detail already written up separately: see the
`wd-mycloud-reboot-persistence` memory/notes.

This device is purely a backup **destination** (`wd_cloud: true` entries
in `unraid_backup_paths`), never a source. Its own RAID/share
configuration is vendor-firmware-level, untouched by OpenVox, and not
something this repo can recreate - recovery there is whatever WD's own
firmware/RAID-rebuild tooling provides.

## Home Assistant - explicitly out of scope

HA is `proxy_only` in the service catalog - `roles::services` only
generates its Caddy route, nothing about the appliance itself is
managed here. **Deliberately not being brought into OpenVox-managed
backup either** - it already backs up to pCloud on its own, separately
from this repo's backup system. This is an intentional independent
backup path.
Recovery for HA is entirely through its own backup/restore mechanism,
not this repo.

## Credentials checklist

Every `vault_*` value needs to exist somewhere outside Git if
`data/common.eyaml` and the eyaml private key are both lost - the key
names are unchanged from the Ansible-era vault, so
`ansible/inventory/group_vars/all/vault.yml.example` (kept as reference,
not consumed by OpenVox) still lists the full set accurately (65 entries
as of this update). The ones that are genuinely painful or impossible to
regenerate identically, not just "annoying":

- **`vault_authelia_storage_encryption_key` / `jwt_secret` /
  `session_secret`** - the single most damaging one to lose. Without
  this exact key, Authelia's existing SQLite DB (WebAuthn credentials,
  2FA enrollment) becomes undecryptable even if the DB file itself is
  restored perfectly from backup. Every user re-enrolls 2FA/WebAuthn
  from scratch.
- **`vault_pcloud_token`** - the OAuth token for the primary offsite
  backup remote. Without it, neither backup role can reach existing
  backups. Re-authenticating rclone against the same pCloud account gets
  a new token, but that's a manual step outside OpenVox.
- **`vault_tuta_email` / `vault_tuta_password`**,
  **`vault_google_client_id/secret`**, **`vault_strava_*`**,
  **`vault_homeassistant_token`** - third-party identities, regenerable
  only by re-authorizing with each provider by hand.
- Postgres passwords (nocturne, forgejo, umami, mail-archiver) only
  matter if trying to reuse an existing volume as-is - restoring from a
  `pg_dump` backup means a fresh container can just get a new password.

## What would be permanently lost today (the honest list)

1. Recreation knowledge for the 11 `managed: false` nas services, if the
   Unraid flash backup ever turns out to not actually restore Docker
   templates cleanly (unverified) - their actual data (appdata + Immich's
   photo library) is now offsite-covered either way, see below.
2. The Tailscale admin console configuration itself (ACLs, tags, the
   `tag:ci` OAuth client) - not exportable/backed-up by anything here.
3. Authelia's 2FA/WebAuthn enrollments, if `vault_authelia_storage_encryption_key`
   is ever lost without the DB (see credentials checklist above).

Fixed during this audit: mail-archiver's backup coverage (was inert,
now real), the generic Postgres-restore gap, and - after re-checking
live rather than trusting the first read of `unraid_backup_paths` alone
- Immich/Vikunja/Dawarich/Syncthing-config's appdata now has an offsite
copy too (the existing weekly AppData Backup plugin output was real and
working, just local-only; see the nas section above for the full
correction), and Syncthing content has multi-peer replication plus
30-day pCloud deleted/overwritten-file recovery via rclone's backup directory.

## Follow-up backlog items generated by this audit

- FIXED: the generic Postgres-restore gap (`restore.sh` imports logical
  PostgreSQL backups through the services' post-deploy hooks). OpenVox's
  explicit fresh-host recovery mode restores raw data before services start,
  deliberately leaves dump-backed PostgreSQL volumes empty, and lets those
  hooks import the matching dump after PostgreSQL is ready.
- FIXED: Immich/Vikunja/Dawarich/Syncthing-config's appdata backup is
  now offsite (`/mnt/user/backup/appdata` added to `unraid_backup_paths`,
  `tier: critical`) - the existing weekly local plugin backup already
  covered them, it just wasn't leaving the array.
- Verify Unraid's flash-drive restore actually recreates the 11
  `managed: false` Docker containers cleanly - or write down manual
  recreation steps for each if it doesn't.
- FIXED (2026-09-02): the `ugreen` section above now records the 2026-07-31
  rebuild as a real procedure: vendor storage boundary, Tailscale/OpenVox
  bootstrap, backup-target repopulation, and validation checks.
- Actually test this runbook against a throwaway VM once resources allow
  - everything above is verified-by-reading-code, not verified-by-doing.
- Revisit the accepted shared-eyaml-key risk after the higher-priority audit
  items are complete. If implemented, use one eyaml file and key pair per host;
  duplicate secrets needed by multiple hosts so each copy has independently
  encrypted ciphertext. This limits a host compromise to that host's secrets,
  at the cost of additional bootstrap, backup, rotation, and CI complexity.
- FIXED (2026-08-29): this doc was still Ansible-vault-framed after the
  2026-08-23 OpenVox cutover - rewritten for the eyaml PKCS7 bootstrap flow.
- Confirm and document, outside this repo, that
  `openvox/keys/private_key.pkcs7.pem` actually has a real backup
  (password manager or equivalent) - it is the single point of failure
  for every `vault_*` secret and this doc cannot verify that for you.
  See `docs/OPENVOX_BACKLOG.md` for the broader OpenVox review backlog
  this DR-doc fix came out of.
