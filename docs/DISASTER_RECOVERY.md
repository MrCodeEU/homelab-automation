# Disaster Recovery Runbook

What it actually takes to get this homelab back from a dead/corrupted/
reinstalled host, host-by-host, and an honest list of what is **not**
covered today. Written from a real audit (2026-08-13), not aspirational -
every gap below was verified against the actual role/catalog code, not
assumed.

Not yet tested against a real from-scratch rebuild (no spare hardware to
throwaway-test against). Treat the steps below as the best current
understanding, not a proven drill. A real test (spin up a VM, run this
doc against it) is its own backlog item.

## Before any of this works at all

Nothing in this repo can turn a bare OS install into an Ansible-
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
3. **`ansible-vault create ansible/inventory/group_vars/all/vault.yml`**,
   filling in every value from `vault.yml.example` (see the credentials
   checklist below).
4. **Have the vault password available.** It's a GitHub Actions secret
   (`ANSIBLE_VAULT_PASSWORD`) for CI; for local runs it has to come from
   wherever it's kept outside this repo (a password manager - confirm
   it's actually there, this doc can't do that for you).
5. **Tooling**: `ansible-galaxy collection install -r ansible/requirements.yml`,
   `pip install ansible-core mitogen ansible-mitogen`, and
   `git config core.hooksPath .githooks`.

**GitHub Actions secrets** (only 3, everything else is Tailscale/Vault):
`TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `ANSIBLE_VAULT_PASSWORD`.

**The single biggest thing this repo cannot back up or reproduce**: the
Tailscale admin console configuration itself - ACLs, device tags, the
`tag:ci` OAuth client scope, and every node's one-time interactive login.
If that's gone, every host needs re-enrolling and re-approving by hand
before Ansible can reach any of them.

## mljr (Rocky, production ingress)

Once Tailscale-enrolled and the vault is in place, a full run of
`ansible-playbook playbooks/site.yml --limit mljr` (or the normal CI
deploy path) brings up: base packages/Docker/firewalld, CrowdSec +
nftables bouncer, Caddy (reverse proxy/ingress + ACME TLS), Authelia
(SSO), Mailcow, Glance, HetrixTools agent, and every `services`-role
catalog entry scoped to `host: mljr`.

`roles/backup` then auto-restores every `backup_critical: true` service
on a detected fresh install (`.initialized` flag missing). Non-critical
services still get their data back if you run `restore.sh --service
<name>` manually.

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

Same mechanism as mljr: `--limit nuc`. Covers TutaBridge CLI (headless
Tuta export), health-report agent, Hawser Docker agent, and every
`services`-role catalog entry scoped to `host: nuc` (mail-archiver,
umami, forgejo, kuma, grafana, and the various demo/utility services).

**TutaBridge specifically** needs one extra thing beyond a plain deploy:
the role handles gnome-keyring bootstrapping and the first Tuta login
automatically (via `ansible.builtin.expect`, since this account has no
TOTP) - no manual step needed here anymore, unlike Outlook's OAuth Device
Code Flow (see mail-archiver below), which does need a human to
visit a URL once per Microsoft account.

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
`tier: critical`, per `roles/unraid-backup/defaults/main.yml`. This is
the single most important thing for Unraid recovery (Unraid's own
guidance): it holds every array/share/plugin/Docker-template
configuration and the license key. Recovery: boot from a fresh flash
drive image, restore this backup onto it, boot.

Also backed up (all `tier: critical`, pCloud + best-effort ugreen/WD
depending on entry): `Fotos/Fotos`, `Fotos/Videos`, `Fotos/Wichtiges
Scans Adressen`, `Fotos/Musik`, and the Nextcloud borg repository.

**11 of 15 nas-hosted catalog services are `managed: false`**
(Unraid-UI-owned containers, Ansible only generates their Caddy proxy
snippet): `nas` (management UI), `immich`, `nextcloud`, `dockhand`,
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

**Still genuinely uncovered**: Syncthing's own *content* folders on nas
(not its config, which the plugin does cover - deliberately deferred
pending the folder restructuring already tracked in the backlog, see
the Syncthing memory notes).

## ugreen (UGreen NAS, UGOS)

Ansible-managed subset only: `syncthing-ugreen`, `oxicloud` (explicitly
an initial test, no backup), `smartctl-exporter`, plus
`host-facts-endpoint`, `grafana-alloy`, `iperf3`, `ugreen-tailscale`
(version-check role, UGOS itself isn't `dnf`-managed by design), and
`backup-remote-target` (the SFTP chroot other hosts push backups into).

Everything else - UGOS's own storage pool layout (mdraid → LVM → btrfs),
network share definitions, UGOS app-store installs - is vendor-appliance
config living entirely outside this repo, deliberately (per the
inventory's own comments: no dnf, vendor A/B overlay root, same posture
as leaving Unraid's own OS layer unmanaged). Recovery for that layer is
whatever UGOS's own recovery/reset process provides - not something
Ansible touches or could reproduce.

Note: this device died catastrophically once already (2026-07-31,
rebuilt on new hardware by 2026-08-10) - that recovery happened, but was
never written up as a repeatable procedure, only left as inventory
comments. Worth doing properly if it's rebuilt again.

## wd_mycloud (WD MyCloud EX2 Ultra)

Only two roles touch it: `wd-mycloud-tailscale` and
`wd-mycloud-node-exporter`, both bare ARM binaries on a persistent data
partition with a boot-hook (hijacked `clamAV/start.sh` - the one thing
confirmed to survive/re-run after a reboot on this BusyBox device, no
systemd/cron persistence otherwise). Full detail already written up
separately: see the `wd-mycloud-reboot-persistence` memory/notes.

This device is purely a backup **destination** (`wd_cloud: true` entries
in `unraid_backup_paths`), never a source. Its own RAID/share
configuration is vendor-firmware-level, untouched by Ansible, and not
something this repo can recreate - recovery there is whatever WD's own
firmware/RAID-rebuild tooling provides.

## Home Assistant - explicitly out of scope

HA is `proxy_only` in the inventory - Ansible only generates its Caddy
route, nothing about the appliance itself is managed here. **Deliberately
not being brought into Ansible-managed backup either** - it already
backs up to pCloud on its own, separately from this repo's backup system
(flagged during this audit as not a great setup, worth a proper look
later, but that's a separate discussion, not part of this pass).
Recovery for HA is entirely through its own backup/restore mechanism,
not this repo.

## Credentials checklist

Every `vault_*` value needs to exist somewhere outside Git if the vault
itself and its password are both lost - see
`ansible/inventory/group_vars/all/vault.yml.example` for the full list
(60+ entries as of this audit). The ones that are genuinely painful or
impossible to regenerate identically, not just "annoying":

- **`vault_authelia_storage_encryption_key` / `jwt_secret` /
  `session_secret`** - the single most damaging one to lose. Without
  this exact key, Authelia's existing SQLite DB (WebAuthn credentials,
  2FA enrollment) becomes undecryptable even if the DB file itself is
  restored perfectly from backup. Every user re-enrolls 2FA/WebAuthn
  from scratch.
- **`vault_pcloud_token`** - the OAuth token for the primary offsite
  backup remote. Without it, neither backup role can reach existing
  backups. Re-authenticating rclone against the same pCloud account gets
  a new token, but that's a manual step outside Ansible.
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
2. Syncthing's content folders on nas (deferred, tracked separately).
3. The Tailscale admin console configuration itself (ACLs, tags, the
   `tag:ci` OAuth client) - not exportable/backed-up by anything here.
4. Authelia's 2FA/WebAuthn enrollments, if `vault_authelia_storage_encryption_key`
   is ever lost without the DB (see credentials checklist above).

Fixed during this audit: mail-archiver's backup coverage (was inert,
now real), the generic Postgres-restore gap, and - after re-checking
live rather than trusting the first read of `unraid_backup_paths` alone
- Immich/Vikunja/Dawarich/Syncthing-config's appdata now has an offsite
copy too (the existing weekly AppData Backup plugin output was real and
working, just local-only; see the nas section above for the full
correction).

## Follow-up backlog items generated by this audit

- FIXED: the generic Postgres-restore gap (`restore.sh.j2` now has a
  `restore_post_hook` for forgejo/mail-archiver/umami/nocturne). Still
  open: wire the fresh-install path into `hooks/post-deploy.sh` so a
  from-scratch rebuild doesn't need a manual second `restore.sh` pass.
- FIXED: Immich/Vikunja/Dawarich/Syncthing-config's appdata backup is
  now offsite (`/mnt/user/backup/appdata` added to `unraid_backup_paths`,
  `tier: critical`) - the existing weekly local plugin backup already
  covered them, it just wasn't leaving the array.
- Verify Unraid's flash-drive restore actually recreates the 11
  `managed: false` Docker containers cleanly - or write down manual
  recreation steps for each if it doesn't.
- Write up ugreen's 2026-07-31 rebuild as a real procedure instead of
  leaving it as inventory comments only, in case it happens again.
- Revisit Home Assistant's own pCloud backup setup (flagged as "not
  really good" during this audit) - separate discussion, not decided
  here.
- Actually test this runbook against a throwaway VM once resources allow
  - everything above is verified-by-reading-code, not verified-by-doing.
- Bring the Tailscale control plane into this repository where the API permits:
  manage ACL grants, tags, tag ownership, and the `tag:ci` OAuth client as code
  (likely OpenTofu), while keeping OAuth secrets and tailnet recovery access
  outside Git. Add an export/check path for settings the provider cannot own.
- Revisit the accepted shared-eyaml-key risk after the higher-priority audit
  items are complete. If implemented, use one eyaml file and key pair per host;
  duplicate secrets needed by multiple hosts so each copy has independently
  encrypted ciphertext. This limits a host compromise to that host's secrets,
  at the cost of additional bootstrap, backup, rotation, and CI complexity.
