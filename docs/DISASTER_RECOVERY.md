# Disaster Recovery Runbook

What it actually takes to get this homelab back from a dead/corrupted/
reinstalled host, host-by-host, and an honest list of what is **not**
covered today. Originally written from a real audit (2026-08-13);
updated 2026-09-02 to reflect OpenVox as the real production deploy
mechanism since 2026-08-23 and its host-scoped EYaml keys (see
`openvox/README.md`) - every gap below was verified against the actual
role/catalog code, not assumed. Rewritten 2026-11-25 for OpenZiti: no
step depends on Tailscale any more (docs/ZERO_TRUST_PLAN.md, Phase 5).
tailscaled is still installed on the hosts until the zero-trust plan is
finished, but nothing here uses it.

`ansible/` was removed 2026-09-02 after a full parity audit confirmed
every role had a real OpenVox equivalent - see `git log` before that date
if the old tree is ever needed. Every recovery step below goes entirely
through OpenVox now - the three roles that looked unported by name
(`syncthing-nas-key`, `unraid-bootstrap`, `wd-mycloud-tailscale`) turned
out to already be covered under different class names
(`roles::unraid_proxy`, `roles::wd_mycloud_proxy`, a static vault
secret) - see `docs/OPENVOX_BACKLOG.md` for the full correction.

`mljr` was rebuilt from scratch for real on 2026-10-24 (Rocky 9 to 10, see
[mljr rebuild notes](#mljr-rebuild-2026-10-24)), and `ugreen` was rebuilt
after the 2026-07-31 failure. Both were before the move to Ziti. The
procedure below has not been drilled end to end yet; the DR drill is the
Phase 5 gate item.

## What has to exist outside the lab

Bootstrap must never depend on a service that only runs inside the lab.
Everything a rebuild needs is here:

| What | Where | Used for |
|---|---|---|
| This repo | GitHub, and the laptop's clone | everything |
| Laptop with the Ziti tunneler, the `laptop-mrcode` identity and opkssh | `scripts/ziti-laptop-tunnel.sh`, `scripts/opkssh-laptop.sh` | daily SSH (`<host>.ziti`), the enrol scripts |
| YubiKey 1 (on person) and YubiKey 2 (at home) | FIDO2 SSH key `homelab-breakglass-yk1/2`; PIV slot `9c` holds the Ziti root CA | break-glass SSH ([BREAKGLASS.md](BREAKGLASS.md)); a new Ziti PKI ([ZITI_PKI.md](ZITI_PKI.md)) |
| Bitwarden | per-host eyaml private keys (labelled by certname), `homelab-recovery` SSH key, `homelab ziti backup age key`, `homelab ziti root CA` | secrets, break-glass without a YubiKey, the controller backup |
| Contabo customer panel | web | mljr: reinstall, console, stop/start |
| deSEC | web, and `DESEC_*` tokens in GitHub | DNS (`dns/`, dnscontrol) |
| pCloud | rclone token in the eyaml (`vault_pcloud_token`) | offsite backups, incl. the age-encrypted Ziti controller bundle |

**The Ziti controller is recoverable from backup**, which is the big
difference to the Tailscale era: its PKI and raft database are backed up
nightly to ugreen and, age-encrypted, to pCloud ([ZITI_DR.md](ZITI_DR.md));
the policy is code (`ziti/tofu/`, `scripts/ziti-tofu.sh`); and the root CA
lives offline on the YubiKeys and in Bitwarden. Losing all of that at once
means a new PKI and re-enrolling every router and identity (see
[Controller and its backups lost](#controller-and-its-backups-lost)).

**Each agent host has its own EYaml private key and encrypted secret file.**
The private keys are outside Git and are backed up in Bitwarden, labelled by
certificate name. If a host's original key is lost, that host's
`openvox/data/secrets/<certname>.eyaml` is permanently undecryptable - PKCS7
has no backdoor - but the other hosts remain unaffected. This replaces the
old shared-key design and the earlier Ansible-vault-password requirement;
there is deliberately no CI unlock secret.

**GitHub Actions secrets**: none for deploys (the eyaml key is never a CI
secret, it's deployed straight to hosts, and CI has no host access since
2026-11-20, docs/DEPLOY_AGENT.md). dnscontrol uses
`DESEC_READ_TOKEN` (repository) and `DESEC_WRITE_TOKEN` (environment
`dns-production`).

## How you reach a host

| Path | Needs | Works when |
|---|---|---|
| `ssh root@<host>.ziti` (opkssh key, `opkssh login` once a day) | laptop tunneler, Authelia, the controller on mljr, **that host's own router** (each host hosts its own `ssh` service) | daily |
| Break-glass key, direct address ([BREAKGLASS.md](BREAKGLASS.md)) | YubiKey or Bitwarden; mljr on its public port 2299, home hosts only from the home LAN | Ziti or Authelia is down, or the host is not on Ziti yet |
| Console | Contabo panel (mljr), keyboard and screen (home hosts) | SSH is gone too |

From outside the home, a home host whose router is down can be reached
only through another home host that is still on Ziti, for example
`ssh -J root@nuc.ziti root@192.168.50.80` for nas (the jump goes over
Ziti, the last hop over the LAN).

## Rebuilding an agent host (mljr, nuc)

Nothing in this repo can turn a bare OS install into an OpenVox-
controllable host by itself. The order, with the reasons:

1. **Install the base OS** with the break-glass public keys for root
   (`breakglass_pubkeys` in `openvox/data/common.yaml`): Rocky Linux 10 for
   both, mljr from the Contabo panel's reinstall dialog (it takes an SSH
   key), nuc from the installer or a kickstart. Without a key there, log
   in with the password once and add the keys by hand. Unraid, UGOS and WD
   are vendor images, see their sections below.
2. **Point `<h>.ziti` at the real address for now.** The repo's scripts
   address hosts only as `<h>.ziti` (and `<h>.int.mljr.eu`), and that name
   has to work before the host is on Ziti. A file that sorts before the
   Ziti one, e.g. `~/.ssh/config.d/00-dr-bootstrap.conf`:

   ```
   # Temporary, remove after the host is back on Ziti (step 8).
   Host mljr.ziti mljr.int.mljr.eu
     HostName 157.173.97.107
     Port 22        # 2299 once the first apply has run (the tarpit takes 22)
     User root
     IdentityFile ~/.ssh/id_ed25519_sk_homelab_yk1
     IdentitiesOnly yes
   ```

   For nuc: `HostName 192.168.50.30`, port 22, from the home LAN. Run the
   scripts with `OPK_SKIP=1` while this block is in place, since the host
   has no opkssh yet. The deploy scripts (`openvox-sync.sh`,
   `openvox-modules.sh`, `openvox-rollback.sh`) ignore every SSH config on
   purpose (`-F /dev/null`); `OPENVOX_SSH_CONFIG=~/.ssh/config.d/00-dr-bootstrap.conf`
   makes them read this one file instead, so the block has to be complete
   on its own (no `Include`, every option it needs written out).
3. **Install OpenVox**: `OPK_SKIP=1 OPENVOX_SSH_CONFIG=~/.ssh/config.d/00-dr-bootstrap.conf
   scripts/install-openvox.sh <h>.int.mljr.eu`. It takes the certname from the name it is given, so
   use the `int.mljr.eu` name, not `<h>.ziti`.
4. **Restore that host's EYaml key pair** from Bitwarden, see
   [EYaml key recovery](#eyaml-key-recovery).
5. **First apply**: with `OPK_SKIP=1` and `OPENVOX_SSH_CONFIG` set as in
   step 3, `make openvox-check-<h>`, then `make openvox-deploy-<h>`. This brings up base, firewall,
   sshd hardening, opkssh, Docker, the deploy agent and every catalog
   service; services that need Ziti (proxies, the router) restart-loop
   until step 7, which is expected. On EL10, reboot into the newest kernel
   after the first apply (netfilter module mismatch, see the 2026-10-24
   notes). On mljr, switch the bootstrap block to port 2299 afterwards.
6. **mljr only: restore the Ziti controller** before anything else Ziti,
   following [ZITI_DR.md](ZITI_DR.md) "Restore onto a rebuilt mljr". Take
   the bundle **from pCloud** (age, key from Bitwarden): mljr's copy on
   ugreen is reachable only through Ziti (`roles::backup::ugreen_host`
   127.0.0.1, the backup-sftp proxy), which needs the controller.
   `ctrl.ziti.mljr.eu` keeps pointing at mljr when the IP stays; with a
   new IP, update `dns/dnsconfig.js` and push it first.
7. **Re-enrol the host's router**: `OPK_SKIP=1 scripts/ziti-enroll-router.sh
   <h> --reenroll`. The router still exists in the controller, but its key
   and certificate were on the lost disk; `--reenroll` issues a new token
   for the same router, so policies, terminators and the router id stay.
   The proxies and the host's `ssh` service come up with it.
8. **Back to the daily path**: delete the bootstrap block, unset
   `OPENVOX_SSH_CONFIG` and `OPK_SKIP`, `opkssh login`,
   then `ssh root@<h>.ziti true`. The host key is new: check it on the
   console or over the break-glass session (`ssh-keygen -lf
   /etc/ssh/ssh_host_ed25519_key.pub`), then replace the old entry
   (`ssh-keygen -R <h>.ziti`). From here, deploys run through
   `deploy.yml` and the deploy agent as usual.
9. **Restore data**, see the host sections below. Backups from ugreen work
   again now (they go through Ziti as well).

### Controller and its backups lost

Only if mljr, the ugreen copy and the pCloud copy (or the age key) are all
gone. Then there is no overlay to recover, only one to rebuild:

1. Sign a new intermediate CA with the offline root on a YubiKey
   (`scripts/ziti-sign-intermediate.sh`, [ZITI_PKI.md](ZITI_PKI.md)).
   If the root is gone too, `scripts/ziti-root-ca-ceremony.sh` first, and
   every client then has to trust the new root.
2. Converge mljr; the controller starts with the new PKI and an empty
   database.
3. Recreate all policy, services and identities from git:
   `scripts/ziti-tofu.sh apply` (show the plan first, as always).
4. Enrol everything again: every router (`scripts/ziti-enroll-router.sh`,
   without `--reenroll`), the proxy and Caddy identities
   (`scripts/ziti-enroll-proxy.sh`, `scripts/ziti-enroll-caddy.sh`), the
   WD tunneler (`scripts/ziti-enroll-wd-mycloud.sh`), the laptop
   (`scripts/ziti-laptop-tunnel.sh`) and the phone
   (`scripts/ziti-enroll-phone.sh`). Until the routers are back, the home
   hosts are reachable only with the break-glass keys from the LAN.

### EYaml key recovery

For an **existing** recovered agent host, restore the exact private key from
its Bitwarden entry, not a newly generated replacement. The certificate name
and active key directory are:

| Host | Certificate name | Active directory |
|------|------------------|------------------|
| `mljr` | `mljr.int.mljr.eu` | `/etc/puppetlabs/puppet/eyaml/hosts/mljr.int.mljr.eu/` |
| `nuc` | `nuc.int.mljr.eu` | `/etc/puppetlabs/puppet/eyaml/hosts/nuc.int.mljr.eu/` |
| `ugreen` | `ugreen.int.mljr.eu` | `/etc/puppetlabs/puppet/eyaml/hosts/ugreen.int.mljr.eu/` |

After OpenVox itself is installed, restore the private key to that directory
as `private_key.pkcs7.pem`, restore the matching public key from
`openvox/keys/<host>/public_key.pkcs7.pem` as `public_key.pkcs7.pem`, then
apply the required ownership and modes:

```bash
install -d -m 0700 /etc/puppetlabs/puppet/eyaml/hosts/<certname>
install -o root -g root -m 0400 private_key.pkcs7.pem \
  /etc/puppetlabs/puppet/eyaml/hosts/<certname>/private_key.pkcs7.pem
install -o root -g root -m 0444 public_key.pkcs7.pem \
  /etc/puppetlabs/puppet/eyaml/hosts/<certname>/public_key.pkcs7.pem
/opt/puppetlabs/puppet/bin/gem install hiera-eyaml --no-document
```

Then run `make openvox-check-<host>` before deployment. Do **not** run
`scripts/bootstrap-openvox-eyaml-host-key.sh` for recovery: it creates a new
key pair and therefore cannot decrypt the already committed ciphertext. That
script is only for a genuinely new host, after which its public key and a new
host secret file must be committed.

`git config core.hooksPath .githooks` sets up the repo's pre-commit hooks
on a fresh clone; it is unrelated to any specific host.

## mljr (Rocky, production ingress)

Once bootstrapped ([steps above](#rebuilding-an-agent-host-mljr-nuc),
including the controller restore), the first apply brings up: base
packages/Docker/firewalld, CrowdSec + nftables bouncer, Caddy (reverse
proxy/ingress + ACME TLS), Authelia (SSO), Mailcow, Glance, HetrixTools
agent, the Ziti controller and public router, and every service-catalog
entry scoped to `host: mljr`.

**Auto-restore on a fresh install is not ported.** Nothing restores data by
itself after the first apply. Restore each service explicitly, either with
`make openvox-recovery HOST=mljr SERVICE=<name>[,<name>...]` (fresh host
only, see the nuc section) or with `restore.sh --service <name> --force` on
the host after stopping that service's containers. This applies to critical
and non-critical services alike.

**Order matters on mljr:** Authelia before anything that logs in through
it (opkssh SSH, the OIDC apps, Ziti enrolment through Authelia). Until
Authelia's database is restored, use the break-glass path.

**Known friction, not data loss:**
- Caddy's ACME/TLS certificate cache isn't backed up - Let's Encrypt just
  reissues automatically once Caddy is back up and DNS resolves, but
  that's a delay and eats into Let's Encrypt's rate limit if it happens
  often.
- DNS records for `mljr.eu` are defined in `dns/dnsconfig.js` (deSEC,
  applied by dnscontrol - see `dns/README.md`). Re-apply with `dnscontrol
  push`. The Mailcow DKIM TXT record is deliberately not in the repo: copy
  it from the Mailcow admin UI (or recover it from the `vmail-vol-1`/
  `mysql-vol-1` backup) into deSEC by hand.
- Mailcow's DKIM keys and mail queue live in Docker volumes covered by
  backup (`vmail-vol-1`, `mysql-vol-1`) - reproducible from backup, but
  slow/tedious per the role's own comments.
- CrowdSec's central-API machine registration is re-registerable but
  tedious (per the role's own comment) - local decisions restore fine
  from backup, but the instance needs to re-enroll with CrowdSec's
  central API.

### mljr rebuild (2026-10-24)

No supported in-place Rocky 9 to 10 upgrade exists (ELevate dropped Rocky),
so mljr was reinstalled from the Contabo Rocky 10 image on the same IP. At
the time it got back onto the tailnet by restoring `tailscaled.state`;
today that is steps 2-8 above instead. Then: OpenVox install, per-host
eyaml key, apply, manual restore. Things that bite on a fresh host:

- The first apply on a fresh EL10 host needs a reboot into the newest kernel
  (netfilter module mismatch).
- Caddy's logs were root-owned and labelled `var_log_t`, so `httpd_t` could
  not open them and Caddy stayed HTTP-only. Fixed in the role; if it recurs,
  `restorecon -R /var/log/caddy`.
- Contabo's cloud-init leaves password SSH login enabled and stores the root
  password in `/var/lib/cloud/instance/user-data.txt`. The role now removes
  cloud-init and dhcpcd on public hosts and ships an sshd hardening drop-in.
  Rotate the root password after the rebuild.
- Mailcow restore (vmail, mysql, data) took about 11 minutes. The backup's
  pre-hook captures `mailcow.conf` and a Redis dump, which holds the DKIM
  keys. The DKIM TXT record in DNS is managed by hand (see above).
- Caddy re-issued about 54 certificates in about 10 minutes through its rate
  limiter. Expect that delay.
- `canarytokens` has no `canarytokens-uploads` volume backup. The restore
  error for it is harmless.

## nuc (Rocky, staging + misc services)

Same mechanism as mljr ([steps above](#rebuilding-an-agent-host-mljr-nuc),
from the home LAN, without step 6). Covers TutaBridge CLI (headless Tuta
export), health-report agent, Hawser Docker agent, the home routers'
management paths (nas, wd_mycloud, HA over its own router and proxies),
VictoriaMetrics/Loki/Grafana, and every service-catalog entry scoped to
`host: nuc` (mail-archiver, umami, forgejo, kuma, grafana, and the various
demo/utility services).

nuc also drives nas and wd_mycloud (`roles::services_nas`, the
`unraid_*` and `wd_mycloud_*` proxies) over `ssh nas-mgmt` and
`ssh wd-mycloud-mgmt`, both through Ziti. Those resources fail until
nuc's router and proxy are back (step 7); the next apply after that
catches up.

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

The flash also holds `/root/.ssh/authorized_keys` (the break-glass keys
and the nas-mgmt key) and the opkssh files (`roles::nas_opkssh`), so a
flash restore brings back SSH access as well. The Ziti router's data
(`/mnt/user/appdata/homelab/ziti-router-nas/data`) is on the array, not
the flash: after an array loss, re-enrol it with
`NAS_SSH=root@192.168.50.80 scripts/ziti-enroll-router.sh nas --reenroll`
from the home LAN (`roles::services_nas` deploys the router service
first).

**nuc's way in (`ssh nas-mgmt`) runs over Ziti through nas's own router**
(`roles::nas_mgmt_key`). It needs that router running and the nas-mgmt
key in `/root/.ssh/authorized_keys` (a symlink to the flash, so it
survives a reboot and a flash restore). When either is missing, the
owner logs in with the recovery key from the LAN, through nuc:
`ssh -i ~/.ssh/homelab-recovery -J root@nuc.ziti root@192.168.50.80`.
Start the router there (`cd /mnt/user/appdata/homelab/ziti-router-nas &&
docker compose up -d`, or the Unraid Docker tab), or add the key line
from `roles::nas_mgmt_key`; the next nuc apply checks and corrects it.

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

OpenVox-managed subset only: `syncthing-ugreen`, `smartctl-exporter`, the
Ziti router `ziti-router-ugreen`, plus `roles::host_facts_endpoint`,
`roles::grafana_alloy`, `roles::iperf3`, `roles::ugreen_tailscale`
(version check only, removed together with tailscaled at the end of the
zero-trust plan), and `roles::backup_remote_target` (the SFTP chroot
other hosts push backups into, reached by them over Ziti). Unlike
mljr/nuc, ugreen has no `roles::base` - see `role::ugreen`'s own comment
for why.

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
2. **Restore connectivity on the LAN.** UGOS keeps root login off, but
   the repo's scripts log in as root. The way in is the one
   `roles::opkssh` sets up later: root with a key, only on connections to
   127.0.0.2. On a fresh UGOS it has to be made by hand once:
   - Enable SSH in the UGOS UI and log in as `mrcode` (the UGOS admin
     user, has sudo) at `192.168.50.86` with its password.
   - Add the break-glass public keys to `~mrcode/.ssh/authorized_keys`
     and to `/root/.ssh/authorized_keys` (directory 0700, file 0600).
   - Write `/etc/ssh/sshd_config.d/11-openvox-opkssh-root.conf` (0600)
     with the content `roles::opkssh` uses (`Match User root LocalAddress
     127.0.0.2`, `PermitRootLogin prohibit-password`, `AuthenticationMethods
     publickey`, `ForceCommand none`, `Match all`), then `sudo sshd -t &&
     sudo systemctl reload ssh`. The first apply takes the file over.

   The bootstrap block (as in [step 2 above](#rebuilding-an-agent-host-mljr-nuc))
   then jumps through `mrcode` to that address:

   ```
   Host ugreen.ziti ugreen.int.mljr.eu
     HostName 127.0.0.2
     ProxyJump mrcode@192.168.50.86
     User root
     IdentityFile ~/.ssh/id_ed25519_sk_homelab_yk1
     IdentitiesOnly yes
   Host 192.168.50.86
     IdentityFile ~/.ssh/id_ed25519_sk_homelab_yk1
     IdentitiesOnly yes
   ```

   Remove the break-glass keys from root's file again after step 5;
   `mrcode` keeps them (`roles::ssh_hardening`).
3. **Install OpenVox for Debian 12.** Add the OpenVox Debian 12 apt source
   (`https://apt.voxpupuli.org`, suite `debian12 openvox8`) and install the
   OpenVox agent. Set its certname to `ugreen.int.mljr.eu`. The
   generic `scripts/install-openvox.sh` is Rocky-only; do not run it here.
4. **Restore Ugreen's existing EYaml key pair** as described in
   [EYaml key recovery](#eyaml-key-recovery), then sync and apply:

   ```bash
   export OPK_SKIP=1 OPENVOX_SSH_CONFIG=~/.ssh/config.d/00-dr-bootstrap.conf
   make openvox-check-ugreen
   make openvox-deploy-ugreen
   ```

   The apply recreates `/volume1/homelab`, the managed Compose services
   (including the Ziti router, which restart-loops until step 5),
   `homelab-facts`, Grafana Alloy, iperf3, the SFTP backup account and
   chroot (`/volume1/homelab-backups/data`), the Btrfs backup-history
   timer and the opkssh login for `mrcode` (`ugreen.ziti` dials
   127.0.0.2, where root login over opkssh is allowed). It deliberately
   does not manage a firewall on Ugreen.
5. **Re-enrol the router**: `OPK_SKIP=1 scripts/ziti-enroll-router.sh
   ugreen --reenroll`, then remove the bootstrap block and check
   `ssh root@ugreen.ziti true` over Ziti (new host key, see step 8 above).
6. **Repopulate the backup target from authoritative sources.** A rebuilt
   Ugreen is an empty *destination*, not a source of truth. Let the next
   backup runs from mljr/nuc/nas upload fresh data; do not try to make an
   incomplete old Ugreen copy authoritative. Its historical Btrfs
   snapshots are lost with the pool and start again after the first new
   backup. The Ziti controller bundle is among them: until mljr's next
   nightly backup, its only copy is the age-encrypted one on pCloud.
7. **Verify before relying on it:** the router is online
   (`ziti edge list edge-routers`), Docker and the expected containers are
   healthy, the SFTP target is writable by the restricted backup user
   (the next mljr/nuc backup run reaches it over `backup-sftp-ugreen`),
   `homelab-backup-snapshot.timer` is enabled, and Grafana and the health
   report see the host again.

## wd_mycloud (WD MyCloud EX2 Ultra)

Only two proxy classes touch it, both run on nuc over SSH (wd_mycloud
has no agent - busybox, no libc match for any Puppet-family runtime):
`roles::wd_mycloud_proxy` and `roles::wd_mycloud_node_exporter_proxy`,
both bare ARM binaries on a persistent data partition with a boot-hook
(hijacked `clamAV/start.sh` - the one thing confirmed to survive/re-run
after a reboot on this BusyBox device, no systemd/cron persistence
otherwise). Full detail already written up separately: see the
`wd-mycloud-reboot-persistence` memory/notes.

nuc reaches it as `ssh wd-mycloud-mgmt` over Ziti, through the
`ziti-edge-tunnel run-host` tunneler on the device itself (identity
`wd-mycloud`, [ZITI_ENROLL.md](ZITI_ENROLL.md) "WD My Cloud"). Every
piece of that (the tunneler, the management key, the boot hook) is
installed over that same path, so after a firmware reset that wipes the
data partition nothing can reach the device from nuc. **Not scripted and
not tested**; the outline:

1. From the LAN with a break-glass key, as `root@192.168.50.176`, add the
   management public key (`wd_mycloud_mgmt_pubkey` in nuc's hiera)
   without its `from=` restriction to root's `authorized_keys`.
2. On nuc, a temporary `/etc/ssh/ssh_config.d/39-dr-wd.conf` with `Host
   wd-mycloud-mgmt` and `HostName 192.168.50.176` (it sorts before the
   managed `40-wd-mycloud-mgmt.conf`, so it wins). If the reset changed
   the device's host key, update `wd_mycloud_host_key` first: the
   managed config pins it.
3. Deploy nuc: it writes the keys (with `from=` again), the boot hook and
   the tunneler. Then `scripts/ziti-enroll-wd-mycloud.sh --reenroll`.
4. Delete `39-dr-wd.conf` and check that `ssh wd-mycloud-mgmt true` on
   nuc works over Ziti.

Losing only the tunneler's identity file is the smaller case: the keys
and boot hook survive. Steps 1 and 2 (the managed key line only accepts
127.0.0.1, so the LAN needs the unrestricted one), then
`scripts/ziti-enroll-wd-mycloud.sh --reenroll`, then step 4.

This device is purely a backup **destination** (`wd_cloud: true` entries
in `unraid_backup_paths`), never a source. Its own RAID/share
configuration is vendor-firmware-level, untouched by OpenVox, and not
something this repo can recreate - recovery there is whatever WD's own
firmware/RAID-rebuild tooling provides.

## Home Assistant - explicitly out of scope

HA is `proxy_only` in the service catalog - `roles::services` only
generates its Caddy route, nothing about the appliance itself is
managed here. Caddy reaches it over Ziti through nuc's router
(`ziti_bind` via nuc). **Deliberately not being brought into
OpenVox-managed backup either** - it already backs up to pCloud on its
own, separately from this repo's backup system. This is an intentional
independent backup path. Recovery for HA is entirely through its own
backup/restore mechanism, not this repo; after a restore, check that its
trusted proxies still include the address nuc's router dials from
(Settings > System > Network).

## Credentials checklist

Every `vault_*` value needs to exist somewhere outside Git if its
host-specific EYaml ciphertext and the matching private key are both lost.
eyaml only encrypts values, not keys, so `openvox/data/secrets/<host>.eyaml`
already lists every `vault_*` name in plaintext per host (the union across
`mljr`/`nuc`/`ugreen` is the full set) - a more current source than the
old Ansible vault example ever was, since it can't drift from what's
actually deployed. The ones that are genuinely painful or impossible to
regenerate identically, not just "annoying":

- **`vault_authelia_storage_encryption_key` / `jwt_secret` /
  `session_secret`** - the single most damaging one to lose. Without
  this exact key, Authelia's existing SQLite DB (WebAuthn credentials,
  2FA enrollment) becomes undecryptable even if the DB file itself is
  restored perfectly from backup. Every user re-enrolls 2FA/WebAuthn
  from scratch. Authelia is also the login for opkssh SSH and every OIDC
  app, so this hurts more than before.
- **`vault_pcloud_token`** - the OAuth token for the primary offsite
  backup remote. Without it, neither backup role can reach existing
  backups. Re-authenticating rclone against the same pCloud account gets
  a new token, but that's a manual step outside OpenVox.
- **The Ziti backup age key** (Bitwarden only, not in eyaml) - the only
  way to read the controller bundle on pCloud when ugreen is lost too.
- **`vault_tuta_email` / `vault_tuta_password`**,
  **`vault_google_client_id/secret`**, **`vault_strava_*`**,
  **`vault_homeassistant_token`** - third-party identities, regenerable
  only by re-authorizing with each provider by hand.
- **`vault_glucava_secret_key`** (nuc eyaml) - encrypts the credentials
  stored inside glucava's database. The `glucava-data` volume backup does
  not contain it, so a restored database is only readable with the same key.
- Postgres passwords (nocturne, forgejo, umami, mail-archiver) only
  matter if trying to reuse an existing volume as-is - restoring from a
  `pg_dump` backup means a fresh container can just get a new password.

## What would be permanently lost today (the honest list)

1. Recreation knowledge for the 11 `managed: false` nas services, if the
   Unraid flash backup ever turns out to not actually restore Docker
   templates cleanly (unverified) - their actual data (appdata + Immich's
   photo library) is now offsite-covered either way, see below.
2. Authelia's 2FA/WebAuthn enrollments, if `vault_authelia_storage_encryption_key`
   is ever lost without the DB (see credentials checklist above).
3. The overlay's identities, if the controller, both of its backup copies
   (or the age key) are lost together: recoverable only by rebuilding the
   PKI and re-enrolling everything ([above](#controller-and-its-backups-lost)).
   Policy is never lost; it is in git.

The Tailscale admin console (ACLs, tags, device logins) used to be on this
list. Nothing depends on it since 2026-11-25.

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
  rebuild as a real procedure: vendor storage boundary, OpenVox
  bootstrap, backup-target repopulation, and validation checks.
- FIXED (2026-11-25): the bootstrap no longer depends on Tailscale: SSH
  over Ziti with opkssh, break-glass keys and a temporary `<h>.ziti`
  bootstrap block before a host is on Ziti, controller restore from its
  own backups, router re-enrolment with `--reenroll`.
- OPEN (Phase 5 gate): the DR drill - rebuild one host from a fresh OS
  with only this runbook, ideally a throwaway VM. Everything above is
  verified by reading code and by the 2026-11-07 controller restore test
  (ZITI_DR.md), not by a full rebuild since the move to Ziti.
- FIXED (2026-09-02): host-scoped EYaml keys and ciphertext. Each agent has
  `data/secrets/<certname>.eyaml`, a distinct private key at
  `/etc/puppetlabs/puppet/eyaml/hosts/<certname>/`, and only its own required
  lookups. Shared values are separately encrypted for every recipient host.
  The old shared key pairs were removed only after all three active keys were
  saved in Bitwarden; the former shared key is retained there only for
  historical Git ciphertext recovery.
- FIXED (2026-08-29): this doc was still Ansible-vault-framed after the
  2026-08-23 OpenVox cutover - rewritten for the eyaml PKCS7 bootstrap flow.
- FIXED (2026-09-02): the exact active private key for each agent is stored
  in Bitwarden under its certificate name. The root-level local copies under
  `openvox/keys/<host>/` are gitignored operator conveniences, not the
  authoritative backup. See `docs/OPENVOX_BACKLOG.md` for the broader
  OpenVox review backlog this DR-doc fix came out of.
