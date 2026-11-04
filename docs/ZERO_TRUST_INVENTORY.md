# Zero Trust Inventory (Phase 0)

Status: **draft, 2026-11-03.** Part of [ZERO_TRUST_PLAN.md](ZERO_TRUST_PLAN.md),
Phase 0. Read-only snapshot of the repo and the live hosts. Entries marked
**(verify)** are inferred from the catalog and still need checking against
live Caddy config or with the owner.

## Auth categories

| # | Category | Target control |
|---|---|---|
| 1 | Human/browser, internal (owner and family only) | OIDC at Caddy (Authelia) or the app's own OIDC login |
| 2 | Human/browser, public (anyone) | Unchanged; hardened public web |
| 3 | Machine-to-machine, internal | OpenZiti service, default-deny |
| 4 | External unauthenticated inbound | Unchanged; CrowdSec and rate limits |

## Headline findings

1. **The host firewall trusts the whole tailnet.** `roles::base` puts
   `100.64.0.0/10` in the firewalld `trusted` zone on every OpenVox host
   (`openvox/modules/roles/manifests/base.pp:40`). nuc also trusts its whole
   LAN, `192.168.50.0/24` (`openvox/data/nodes/nuc.tail33930.ts.net.yaml`).
   Any tailnet node reaches every port on these hosts. The only control left
   is the Tailscale ACL.
2. **The Tailscale ACL allows everything and is not in the repo.**
   `docs/DISASTER_RECOVERY.md` already calls the Tailscale admin console
   "the single biggest thing this repo cannot back up or reproduce". The
   policy (exported 2026-11-04) is the default allow-all:
   - `grants`: one rule, `src: ["*"], dst: ["*"], ip: ["*"]`. Every tailnet
     device reaches every port on every other device.
   - `ssh`: `tag:ssh` to `tag:ssh-target` as non-root and `root`;
     **`tag:ci` to `tag:ssh-target` as `ssh-user` and `root`**, so CI holds
     standing root SSH on every target; members to their own devices in
     check mode. The third rule's users list contains a typo,
     `"autogrpud:nonroot"`.
   - `tagOwners`: `tag:ci`, `tag:mljr`, `tag:ssh` (admins),
     `tag:ssh-target` (owner account).
   - No `tests`, no postures, no `groups`.

   Together with finding 1, the network is flat across the whole tailnet,
   with no versioned policy and no backup.
3. **All admin SSH is Tailscale SSH.** There is no repo-tracked key and no
   break-glass path that works without Tailscale. CI reaches hosts as
   `tag:ci` via the Tailscale OAuth client.
4. **Most sockets listen on all interfaces.** See the
   [listening sockets baseline](#listening-sockets-baseline). Containers that
   publish on `0.0.0.0` are reachable from the tailnet and, on nas, ugreen
   and nuc, from the LAN.
5. **Tailscale names and IPs are hard-wired.** `tail33930` appears 130 times
   in 85 files (certnames, `site.pp`, `caddy.pp` upstreams, Makefile, CI, WD
   scripts). There are about 40 hardcoded `100.100.x.x` addresses, plus the
   `tailscale_hosts` map in `openvox/data/common.yaml`. wd_mycloud
   (`100.100.10.5`) is missing from that map and hardcoded in its scripts
   instead.
6. **Many category-1 web apps rely only on their own login page,** with no
   `caddy_auth`, so the login page is public. See the
   [service classification](#service-classification) below.
7. **Three internal UIs are on the public internet without Authelia**
   (checked from outside 2026-11-03): nuc's Cockpit login (`nuc.mljr.eu`),
   the Glance dashboard (`dash.mljr.eu`, no login at all) and the Netronome
   speedtest UI (`speedtest.mljr.eu`). Fix in
   [#496](https://github.com/MrCodeEU/homelab-automation/pull/496):
   `caddy_auth: authelia` on all three, and `two_factor` for both Cockpit
   vhosts.

## Service classification

From `services_catalog` in `openvox/data/common.yaml`. Auth column:
`authelia` means `caddy_auth: authelia`; `app` means no Caddy auth, so the
app's own login (or OIDC client) is the only gate.

### Category 1: human, internal

| Service | Host | Domain | Auth today | Note |
|---|---|---|---|---|
| actual-budget | nuc | budget.mljr.eu | app (OIDC via Authelia) | |
| sure | nuc | sure.mljr.eu | app (OIDC via Authelia) | |
| defectdojo | nuc | dojo.mljr.eu | authelia | importers bypass via `100.100.10.1:8101` (cat 3) |
| backup-dashboard | nuc | backup.mljr.eu | authelia | |
| grafana | nuc | monitor/grafana.mljr.eu | authelia | |
| mail-archiver | nuc | mail-archive.mljr.eu | authelia | |
| goaccess | mljr | logs.mljr.eu | authelia | |
| crowdsec | mljr | crowdsec/security.mljr.eu | authelia | |
| cockpit | mljr | cockpit.mljr.eu | authelia | |
| nas | nas | nas.mljr.eu | authelia | Unraid UI |
| auto-media-sort | nas | sort.mljr.eu | authelia | |
| dockhand | nas | dockhand.mljr.eu | authelia | |
| syncthing | nas | sync.mljr.eu | authelia | |
| paperless | nas | paperless.mljr.eu | authelia | |
| kuma | nuc | uptime.mljr.eu | app | public login page; stays public for now (owner, 2026-11-04) |
| nuc-webui | nuc | nuc.mljr.eu | app | **Confirmed 2026-11-03: Cockpit login page for nuc is reachable from the internet with no Authelia**, unlike mljr's cockpit |
| glance | mljr | dash.mljr.eu | none | **Confirmed 2026-11-03: dashboard is public, no login** (HTTP 200, lists services) |
| homeassistant | homeassistant | home.mljr.eu | app | |
| nocturne | nuc | nc.mljr.eu | app | health data |
| nextcloud | nas | cloud.mljr.eu | app | |
| immich | nas | immich.mljr.eu | app | |
| dawarich | nas | dawarich.mljr.eu | app | location history |
| opencloud | nas | files.mljr.eu | app | migration on hold |
| speedtest | nuc | speedtest.mljr.eu | none | **Confirmed 2026-11-03: Netronome UI is public, no login seen** |
| ntfy | mljr | ntfy.mljr.eu | app (topic whitelist) | phone push needs public reach |

### Category 2: human, public

| Service | Host | Domain | Note |
|---|---|---|---|
| homepage | mljr | mljr.eu | |
| status | mljr | status.mljr.eu | |
| authelia | mljr | auth.mljr.eu | IdP login must be public |
| mailcow | mljr | mail.mljr.eu | plus SMTP/IMAP protocols |
| glucava | nuc | glucava.mljr.eu | own login; stays public for now |
| forgejo | nuc | git/forge.mljr.eu | stays public for now |
| umami | nuc | umami.mljr.eu | tracker endpoint public, dashboard too for now |
| projects | nas | projects.mljr.eu | stays public for now |
| ui-showcase, regex, cron, codec, newsletter, weather-cli | mljr | various | small public apps |
| wordwiz, sudoku, gameoflife, cglab, godrive-demo, service-template | nuc | various | small public apps |

### Category 3: machine-to-machine (no domain)

healthreport, crowdsec-nuc, crowdsec-nas, paperless-mail-export,
dmarc-monitor, diun, nas-alloy, iperf3-nas, netronome-agent-nas, ollama,
immich-kiosk, photon, nextcloud-notify, syncthing-ugreen, oxicloud,
smartctl-exporter (ugreen, nuc, nas), caddy-poc. Their flows are listed
below.

### Category 4: external, unauthenticated inbound

csp-reports (`csp.mljr.eu`), canarytokens (`canary.mljr.eu`), hellpot,
endlessh, spidertrap, the umami tracker endpoint, mailcow SMTP inbound.

### Disabled or legacy entries

test-ocis, stats, pairdrop and homeserver-ui are disabled. `nuc.mljr.eu`
appears twice (homeserver-ui disabled, nuc-webui enabled).

## Machine-to-machine flows

All of these run over Tailscale today. Each one becomes a Ziti service in
Phase 4/5.

| From | To | Port / protocol | Source in repo |
|---|---|---|---|
| mljr Caddy | every non-local backend via `<host>.tail33930.ts.net` | HTTP(S) per catalog port | `openvox/modules/roles/manifests/caddy.pp:276` |
| Alloy (mljr, nuc, ugreen, nas) | nuc VictoriaMetrics, Loki | 19090, 3100 | `grafana_alloy.pp:36`, `services/nas-alloy/config.alloy` |
| nuc Alloy | homeassistant, wd_mycloud node_exporter | 8123, 9100 | `templates/grafana_alloy/config.alloy.epp:99,156` |
| healthreport (nuc) | mljr, nuc, nas, ugreen `homelab-facts` | SSH forced command, `from="100.100.10.1"` | `env.epp:195`, `unraid_host_facts_proxy.pp:49` |
| healthreport (nuc) | Home Assistant API | 8123 | `tools/internal/healthreport/config.go:193` |
| backup-dashboard (nuc) | mljr, nuc, nas, ugreen | SSH | `env.epp:321` |
| crowdsec agents (nuc, nas) | crowdsec LAPI on mljr | 8088 | `env.epp:271,282` |
| nas backup (rclone) | ugreen SFTP chroot | 22 (SFTP) | `files/unraid_backup/rclone-ugreen-content.conf` |
| nuc backup | ugreen SFTP chroot | 22 (SFTP) | `roles::backup_remote_key` |
| nas, nuc backup | pCloud | HTTPS (internet) | `backup.pp:471` |
| vuln_scan (mljr, nuc, ugreen) | defectdojo on nuc | 8101 | node yaml `roles::vuln_scan::dojo_url` |
| paperless-mail-export (nuc) | mail-archiver on nuc | 5000 | `tools/cmd/paperless-mail-export/main.go:515` |
| grafana (nuc) | Postgres on nuc | 5432 | `services/grafana/provisioning/datasources/datasources.yml` |
| kuma (nuc) | crowdsec LAPI, mailcow SMTP, defectdojo | 8088, 25, 8101 | `tools/cmd/provision-kuma/main.go:54-63` |
| dawarich (nas) | photon (nas) | 2322 | `services/dawarich/docker-compose.yml` |
| syncthing (nas) | syncthing-ugreen | Syncthing protocol | `roles::services_ugreen` |
| dockhand (nas) | hawser agents on mljr, nuc | hawser port | `roles::hawser_agent` |
| CI runner (`tag:ci`) | mljr, nuc, ugreen | SSH + rsync | `.github/workflows/deploy.yml:301` |
| nuc (proxy exec) | nas, wd_mycloud | SSH | `role::nuc` |
| actual-budget, glucava | trust mljr as proxy | `TRUSTED_PROXIES=100.100.20.1` | compose files |

## Listening sockets baseline

Measured 2026-11-03 with `ss -tlnu` over Tailscale SSH (TCP and UDP
listeners, de-duplicated by address and port). "All" means bound to
`0.0.0.0`/`[::]`; "other" covers link-local and Docker bridge addresses.

| Host | All interfaces | Tailnet only | LAN only | Loopback | Other |
|---|---|---|---|---|---|
| mljr | 24 | 5 | 0 | 30 | 2 |
| nuc | 46 | 11 | 0 | 5 | 2 |
| ugreen | 72 | 2 | 5 | 17 | 6 |
| nas | 70 | 14 | 10 | 14 | 76 |
| wd_mycloud | 40 | 2 | 6 | 6 | 1 |

### Home Assistant (measured 2026-11-04)

Home Assistant Green (aarch64), HA OS 18.4, Core 2026.10.4. LAN
`192.168.50.31`, tailnet `100.100.10.200` via the Tailscale add-on 0.30.5.
Measured over the Advanced SSH & Web Terminal add-on (24.2.0, protection
mode on). Public-key login could not be made to work in the add-on, so a
temporary password was set for this measurement and reset afterwards.

Listeners (TCP and UDP, de-duplicated): **17 on all interfaces** (IPv4),
plus their IPv6 twins, 2 tailnet-only, 5 LAN-only, 5 loopback, 6 on the
`hassio` bridge (`172.30.32.1`). Notable ones on all interfaces:

| Port | What |
|---|---|
| 22/tcp | Advanced SSH add-on `sshd` (host network) |
| 8123/tcp | Home Assistant Core (no TLS; `home.mljr.eu` via Caddy) |
| 5201/tcp+udp | iPerf3 Server add-on |
| 4416/tcp | YT Music PO Token Generator add-on |
| 111/tcp+udp | rpcbind |
| 4357/tcp, 18555/tcp, 39342/tcp | HA OS / Core internals (go2rtc and others) |
| 1900/udp, 5353/udp, 5355 | SSDP, mDNS, LLMNR (discovery) |

Started add-ons: Matter Server (host network, 5580), OpenThread Border
Router (host network, 8080/8081), Tailscale (host network), Advanced SSH
(host network), iPerf3 Server, Claude Code, YT Music PO Token Generator.

Zero trust notes:
- Home Assistant OS cannot run a Ziti tunneler on the host; see the plan's
  Phase 5 (nuc-hosted Ziti services forwarding to `192.168.50.31`).
- Tailscale SSH is not available; SSH is the add-on's own `sshd`.
- Key-based SSH login to the add-on did not work (cause unknown). This
  blocks `ed25519-sk` break-glass for Home Assistant until solved, so
  Phase 1 must include it. wd_mycloud runs a real OpenSSH `sshd`
(8.4p1) on `0.0.0.0:22`, so `ed25519-sk` break-glass keys work there.

## Metrics baseline

| Metric | Value (2026-11-03) |
|---|---|
| Shell glue in `openvox/` | 167 `.sh` files, 5,955 lines |
| `exec` resources in `openvox/` | 113 |
| Puppet manifests | 5,646 lines |
| Go tools maintained | 15 commands under `tools/cmd`, 13,660 lines (excluding tests and `tools/thirdparty`) |
| Helper scripts | 13 files in `scripts/` |
| Steps to onboard a service | 5 (catalog entry, compose file, secrets **plus** a hand-written mapping in `services.pp`/`services_nas.pp`, optional staging, test + check) |
| Steps to onboard a host | 6 manual prerequisites (OS, interactive Tailscale enrolment and console approval, OpenVox install, eyaml key, sync/apply, hooks), plus a node yaml file, a `site.pp` node block and a role class |
| Deploy workflow wall time | 180-866 s over the last 10 successful runs (most 190-360 s) |
| Drift check wall time | 308-383 s over the last 5 runs |
| Tailscale name references | 130 in 85 files |
| Hardcoded tailnet IPs | about 40 places |
| LAN throughput nas to ugreen | 99 Mbit/s over the LAN (`192.168.50.86`), 86 Mbit/s over Tailscale (`100.100.10.4`); iperf3, 10 s, 2026-11-04 |

**Side finding, not zero trust:** nas (`eth0`) and ugreen (`eth0`) both
negotiate 2.5 Gbit/s full duplex and sit on the same /24 (direct L2 route),
yet iperf3 tops out at about 110 Mbit/s with retransmits. Cause (owner,
2026-11-04): the path crosses FRITZ!Box mesh hops that can't go faster.
No upgrade is expected soon, so this ~100 Mbit/s ceiling is the baseline
the Phase 3 "Ziti must not regress LAN throughput" criterion compares
against.

### Qualitative baseline

- **Access flow on one page:** no. Access is decided by an unversioned
  Tailscale ACL, a wide-open firewalld trusted zone, Authelia on a subset of
  vhosts, and per-app logins.
- **DR drill from docs alone:** partly. mljr (2026-10-24) and ugreen were
  rebuilt for real; nuc, nas (Unraid flash) and wd_mycloud were never
  drilled. The Tailscale console state cannot be restored from anything.
- **Failure diagnosis:** a Tailscale ACL denial looks like a timeout.
- **Distinct trust boundaries:** 4 (Tailscale ACL, firewalld, Authelia,
  app login), only 2 of them in git.

## Current DR dependency chain

1. Bitwarden (eyaml private keys per host).
2. Tailscale admin console: interactive enrolment, device approval, ACL
   tags, `tag:ci` OAuth client. **Not reproducible from git.**
3. OS install, then `scripts/install-openvox.sh` (Rocky) or the Debian
   bootstrap (ugreen).
4. Restore the eyaml key from Bitwarden.
5. `make openvox-deploy-<host>` (rsync over Tailscale SSH, then
   `puppet apply`).
6. Restore data from backups: ugreen SFTP, pCloud (rclone token from
   eyaml), Unraid flash backup, Unraid AppData Backup plugin.

nas and wd_mycloud have no agent. They depend on nuc being rebuilt first,
because nuc drives them through proxy `exec`.

## Phase 0 status

Complete 2026-11-04. Resolved: kuma, forgejo, umami, projects and glucava **stay
public for now** (owner decision), revisited in Phase 7. No device fits the
guest WLAN, so that step is dropped.
