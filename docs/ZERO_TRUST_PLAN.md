# Zero Trust Architecture Plan

Status: **planned, not started** (decided 2026-11-03 in a design-review
session, then reviewed again the same day for gaps and edge cases).
Supersedes the 2026-09-17 Tailscale-ACL-based scoping.

## Goal

This is a learning playground first. The concrete security goal is to
**reduce lateral movement**: every connection is authenticated and
authorized by identity, default-deny, and a compromised host or container
can reach only what its role needs.

Out of scope: hardware attestation, textbook NIST 800-207 completeness,
multi-admin workflows, new network hardware.

## Constraints

- **One architecture, delivered in gated phases.** Each phase leaves the
  fleet fully working, has a written rollback, and ends in a real
  go / change course / stop decision.
- **Tailscale stays in parallel until the final gate**, and most likely
  stays afterwards as the remote break-glass path (see
  [Break-glass](#break-glass)).
- **Language:** everything we write ourselves is Go. Third-party Ruby
  (OpenVox, OpenBolt) is acceptable. No Python.
- **DR target:** rebuild any host from a fresh OS install using only the git
  repo, the host's secrets key, backups, and a laptop. Every component must
  pass a drill of this.
- **Judged on** implementation effort and the security/usability tradeoff,
  measured against the Phase 0 baseline.

## Target architecture

| Concern | Decision |
|---|---|
| Overlay (machine + admin plane) | **OpenZiti**: SSH, exporters, backups, config management, service-to-service. Dark services, no inbound ports at home. |
| Web apps (human, browser) | Stay on **Caddy + OIDC** at the reverse proxy. No Ziti client needed for browsers, phones or family members. |
| Ziti controller | **mljr** (only publicly reachable host), plus a public edge router. **nuc** runs a private edge router (dials out). Always addressed by a stable DNS name (`ctrl.ziti.mljr.eu`), never by IP, because routers cache the controller's advertise address. No HA cluster: quorum needs 3 nodes, and HA v2.0.4+ has a known deadlock bug ([openziti/ziti#4542](https://github.com/openziti/ziti/issues/4542)). |
| Ziti PKI | **Root CA offline** (YubiKey or Bitwarden). Only an intermediate signing CA lives on mljr. |
| Ziti policy | **Policy as code** generated from `services_catalog`, tag-based, default-deny. Applied with **OpenTofu** and a Ziti provider (native state encryption, key in Bitwarden). Fallback is a small Go reconciler on the management API. Replaces the open "Tailscale ACL as code" backlog item. |
| Ziti identities | **Disposable.** On rebuild, re-enrol instead of restoring identity files, so they never need backing up. Cert expiry is monitored. |
| Hostnames / certnames | Move OpenVox certnames, eyaml key paths, node blocks and hiera data off `*.tail33930.ts.net` to **`<host>.int.mljr.eu`**, while Tailscale still works as a safety net. `int.mljr.eu` is **identity-only**: no public DNS records (no leak of internal names, fail-closed). It becomes the Ziti intercept domain later; short names like `ssh root@mljr` then come from a client search domain `int.mljr.eu` plus a wildcard intercept `*.int.mljr.eu`, not from per-host SSH aliases. |
| SSH auth | Plain OpenSSH keys, in git, distributed by OpenVox. Ziti authenticates the network path in front. An SSH CA is a possible later step, decided at the final gate. |
| Identity provider | **Authelia stays the default.** Zitadel is a time-boxed PoC with written pass/fail criteria. |
| Config management | **Working hypothesis (option B):** masterless OpenVox on mljr/nuc/ugreen (unchanged), plus **OpenBolt** as the push layer for laptop bootstrap, DR rebuilds and the appliances (nas, wd_mycloud). CFEngine stays dropped: it is a pull agent of the same class as `puppet apply`. A Go-native IaC tool was searched for again and none is mature. |
| Who runs what | **Laptop:** bootstrap, Ziti enrolment, DR (OpenBolt), YubiKey. **CI** (GitHub-hosted runner): routine convergence through an ephemeral, least-privilege Ziti identity per run. Preferred mechanism: a Ziti external JWT signer trusting GitHub Actions OIDC tokens, scoped by repo and ref, so there is no enrolment step and no stored credential (unverified, PoC item). Nothing new runs permanently on hosts except the existing OpenVox agent and the Ziti tunneler. |
| Devices | Laptop gets a Ziti identity from day one. Phone is optional and later. |
| Host-level controls | firewalld default-deny inbound per host, per-stack Docker networks, restricted container egress. Late phase. |
| Home LAN | The FRITZ!Box has no VLAN support, so the home LAN stays flat (accepted risk). The guest WLAN was considered and dropped: no device fits it (owner, 2026-11-04). |
| Home Assistant | Home Assistant OS is an appliance: no tunneler install on the host. nuc's Ziti router or tunneler **hosts the Home Assistant services** (SSH, API on 8123, scrape target) and forwards them over the LAN. A Ziti tunneler packaged as a Home Assistant add-on is a possible alternative, unverified. SSH today comes from the Advanced SSH & Web Terminal add-on, reached over the Tailscale add-on's network; Tailscale SSH is not available on Home Assistant. |
| Versions | Controller, routers and tunnelers pinned via OpenVox and Renovate. Upgrade order: controller first, then routers, then tunnelers. |
| Visibility | Ziti metrics, policy denials, enrolments, new identities and break-glass use go to VictoriaMetrics and healthreport. Break-glass use and every new identity raise an alert. One "overlay down" alert suppresses the per-scrape alerts it would otherwise cause. |

### Accepted risks

Written down so they are decisions, not surprises.

1. **Compromised mljr means a compromised Ziti controller.** mljr is the most
   exposed host. Mitigations: offline root CA (only an intermediate on
   mljr), controller in its own container and user separate from the web
   stack, management API bound to localhost or Ziti only (never public),
   alert on every new identity. Residual risk: an attacker with root on mljr
   can still mint identities with the intermediate until detected.
2. **The web plane does not shrink.** Caddy on mljr still reaches every home
   web backend. Ziti narrows machine-to-machine traffic only. A compromised
   mljr keeps reach to all web backends.
3. **Flat home LAN.** Without VLANs, every device on the home LAN (Home
   Assistant devices, the Unraid and Ugreen vendor web UIs) can reach the
   servers' LAN-side ports. Real segmentation would need a managed switch or
   a second router, which is out of scope. This also covers the LAN hop
   from nuc to Home Assistant.
4. **Tailscale stays in the trust base** as the remote break-glass path for
   the home hosts, locked down by ACL to break-glass SSH only.

### Root of trust

- **Single root of trust:** Bitwarden, hosted outside the lab and protected
  by hardware keys, with an offline printed recovery copy. It holds the
  per-host eyaml private keys (already the case, see
  [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md)), backup passphrases, the
  Ziti offline root CA, the OpenTofu state encryption key and the
  break-glass SSH key.
- **Two YubiKeys,** registered everywhere the first one is used: Bitwarden,
  break-glass SSH, the Ziti root CA. The second is kept off site. Losing one
  must never lose access.

### Break-glass

Independent of Ziti and the IdP, exempt from zero trust, audited and
alarmed.

| Host | Remote | On site |
|---|---|---|
| mljr | Contabo panel (console); Tailscale (break-glass ACL) | n/a |
| nuc, ugreen, nas, wd_mycloud | Tailscale (break-glass ACL only) | LAN SSH with a YubiKey `ed25519-sk` key, Bitwarden-stored key as fallback |

**SSH server check (2026-11-03/04):** nuc OpenSSH 9.9p1, ugreen 9.2p1,
nas 10.3p1, wd_mycloud OpenSSH 8.4p1 (armv7l, real `sshd` listening on
`0.0.0.0:22`). All are at least 8.2, so `-sk` keys are supported.

### DR bootstrap order (target)

1. Laptop, a YubiKey and Bitwarden available (all outside the lab).
2. If mljr failed: **rebuild mljr first** from the Contabo panel, restore
   the Ziti controller from its snapshot, repoint `ctrl.ziti.mljr.eu`.
   Restoring the controller onto nuc is a **degraded emergency mode only**:
   LAN-only, with a temporary port forward on the FRITZ!Box if outside
   clients must connect.
3. Enrol the rebuilt host with a fresh one-time Ziti JWT pushed from the
   laptop (OpenBolt). Restore its eyaml key from Bitwarden.
4. Converge with OpenVox. Restore volumes from backups.
5. If the controller itself was lost and its snapshot too, recreate all
   policy from git with OpenTofu.

Bootstrap must never depend on a service that only runs inside the lab.

## Phases

Each phase ends with a gate: review its exit criteria against the
baseline and decide go, change course, or stop. Each phase lists its
rollback.

### Phase 0: Baseline and inventory (read-only)

- Classify every service into the four auth categories:
  1. Human/browser internal (OIDC at Caddy).
  2. Human/browser public (mljr.eu).
  3. Machine-to-machine internal (Ziti).
  4. External unauthenticated inbound (CSP reports, DMARC, webhooks; stays
     CrowdSec/rate-limit defended).

  Output: `docs/ZERO_TRUST_INVENTORY.md`.
- List every place that depends on a `*.tail33930.ts.net` name (certnames,
  eyaml paths, hiera, scripts, CI, monitoring targets).
- Record the metrics baseline (see [Metrics](#metrics)), including an iperf3
  LAN baseline between nas and ugreen.
- Document today's DR dependency chain end to end.

**Rollback:** none needed (read-only).
**Gate:** the inventory is complete and no service is left unclassified.

### Phase 1: Break-glass and root of trust

- Buy and register the second YubiKey.
- Enrol `ed25519-sk` keys from both YubiKeys on every host class; store the
  fallback key in Bitwarden. Home Assistant first needs working key-based
  login in the Advanced SSH add-on (it failed in Phase 0, cause unknown). Confirm the Bitwarden recovery copy exists
  offline.
- Lock Tailscale ACLs down towards the break-glass role it will keep.
- Alert on break-glass key use (sshd log, then healthreport).
- **Drill on site:** reach every home host over LAN with Tailscale stopped,
  using break-glass only; reach mljr through the Contabo panel. Never stop
  Tailscale on nas or wd_mycloud remotely.

**Rollback:** remove the added keys; revert the ACL change.
**Gate:** every host is reachable through break-glass with Tailscale off.

### Phase 2: Certname decoupling

- Introduce `<host>.int.mljr.eu` as identity names only (no DNS records,
  see the decision table).
- Rename OpenVox certnames, move eyaml key paths, node blocks and hiera
  data, one host at a time, update the Bitwarden entries.
- `scripts/openvox-sync.sh` maps each SSH target to its certname and passes
  `--certname` to `puppet apply`, so identity and transport are separate.
  The eyaml helper scripts make the same split.
- Transport references (SSH targets, CI host lists, `reverse_proxy` and
  monitoring URLs, appliance proxy scripts) stay on `*.tail33930.ts.net`:
  without DNS, `int.mljr.eu` only resolves once the Ziti tunneler exists.
  They move in Phase 4.

**Rollback:** per host, revert the commit. The on-host eyaml key dir was
copied, not moved, so the old one is still in place (Tailscale still
provides connectivity throughout).
**Gate:** `grep tail33930` finds no identity use left (node files, secrets
files, eyaml key dirs, `node` blocks, certnames). Transport uses are
expected until Phase 4.

Done 2026-11-04 (#502 nuc, #503 ugreen, #504 mljr), each verified by a
live noop and apply under the new certname.

### Phase 3: OpenZiti PoC (throwaway quality)

- Controller (own container and user) and public edge router on mljr,
  private edge router on nuc, laptop identity. Offline root CA from day
  one.
- Containers, not RPMs: the official `openziti/ziti-controller` and
  `openziti/ziti-router` images, pinned by version and digest (2.0.8 at
  the start; the `latest` tag follows the last release pushed, which was
  1.6.22), deployed like every other service. `network_mode: host`, so
  firewalld governs the Ziti ports (ports published through Docker bypass
  it) and the data path has no NAT. RPMs would work on EL10 too, but a
  `dnf upgrade` could move Ziti unexpectedly.
- Ziti gets its own public ports on mljr (for example `8441` controller,
  `8442` router edge), opened in firewalld. It does not share `443` with
  Caddy, so neither depends on the other.
- Controller as built (`services/ziti-controller/`): `8441` public for the
  router control channel, client API and OIDC; management and fabric API on
  `127.0.0.1:8440` only, reached through an SSH tunnel. Admin over
  Tailscale's IP would need that IP in the server certificate; loopback is
  stricter and needs nothing extra. Trust domain `spiffe://ziti.mljr.eu`
  from the intermediate (docs/ZITI_PKI.md). `ctrl.ziti.mljr.eu` is an
  explicit DNS record with TTL 3600 (deSEC minimum).
- Routers as built (`services/ziti-router/`, `services/ziti-router-nuc/`):
  mljr's public router (`#public`) serves edge and link on one port,
  `8442` (`router.ziti.mljr.eu`); the router multiplexes them, so no
  separate link port. nuc's router (`#lan`) is outbound only (control
  channel and link dialed to mljr), with its edge listener on
  `192.168.50.30:8442` (LAN, trusted zone). Both run the host-mode tunnel
  binding, so they host services themselves. Enrolment:
  `scripts/ziti-enroll-router.sh <mljr|nuc> [--reenroll]` hands a one-time
  token from the controller to the router over SSH; certificates (1 year)
  are renewed at every router start (`--extend`).
- One non-critical service reachable only over Ziti: nuc's Grafana Alloy
  metrics endpoint (`127.0.0.1:12345`; nuc runs no node-exporter, Alloy
  collects host metrics). The Grafana UI follows only if there is time
  left. Services and policies: `scripts/ziti-poc-objects.sh` (idempotent,
  default deny: `#admin` identities dial `#admin-services`, each service
  bound by one router identity). Shared policies come before services: a
  router whose first terminator request is rejected does not retry until
  it restarts.
- Laptop (C8): `ziti/laptop/ziti-edge-tunnel.container`, a root Quadlet
  (no layering), installed and enrolled by `scripts/ziti-laptop-tunnel.sh`
  as `laptop-mrcode` (`#admin`). Tunneler fake IPs in `198.18.0.0/16`,
  because the default `100.64.0.0/10` overlaps Tailscale. It registers
  `~.` on its link when Tailscale already has `~.`, so resolved asks both.
- Short names (C10): one `ssh` service intercepts `<host>.int.mljr.eu:22`
  for the hosts on Ziti and dials the terminator named after the hostname
  (`$dst_hostname`); each router binds under its identity name, so routers
  are named after their certname (`nuc.int.mljr.eu`). The router-embedded
  tunneler does not resolve `$tunneler_id.tag[...]`. Short names come from
  SSH canonicalization (`ziti/laptop/ssh-int-mljr-eu.conf`): `ssh root@nuc`
  tries `nuc.int.mljr.eu` first, which only resolves while the tunneler is
  up, and falls back to MagicDNS/LAN otherwise and for hosts not on Ziti.
  Resolution order next to MagicDNS: a resolved search domain does not
  work, because resolved asks every link with search domains in parallel
  (`tailscale0`, `wlan0`'s `fritz.box`, `ziti0`) and takes the first
  positive answer; Tailscale or the FRITZ!Box won. The intercept lists
  hosts instead of `*.int.mljr.eu`, since a wildcard resolves every name
  and blocks that fallback. `TXT int` stops the public `*` wildcard, so
  `*.int.mljr.eu` is NXDOMAIN publicly. Non-SSH tools use the FQDN. sshd
  over Ziti sees `127.0.0.1` and needs a key in its own list (Tailscale SSH
  needs none); the everyday admin key is a Phase 4 decision.
- Visibility (C11): the controller serves Prometheus `/metrics` on its
  loopback admin listener; mljr's Alloy scrapes it (job `ziti-controller`).
  It includes the metrics every router reports (`source_id` = router id),
  which vanish while a router is offline. The controller writes an event
  log (`entityChange`, `authentication`, `router`, `circuit`, `sdk`;
  rotated at 10 MB, 3 kept) that Alloy tails into Loki (job `ziti-events`,
  label `namespace`). Grafana alert rules are provisioned from
  `services/grafana/provisioning/alerting/ziti.yml` and notify ntfy topic
  `homelab-security`: controller down, router offline, identity created
  or enrolled, failed logins, failed circuits. Policy denials have no
  event of their own: a client is never issued a session for a service it
  may not dial, so failed logins and refused circuits stand in for them.
  Still to do in Phase 3: fire the controller-down, router-offline and
  circuit-failure rules once on purpose, and add and test an alert for the
  nuc-mljr link going down while both routers stay up. The controller's
  `ziti_link_*` metrics carry `sourceRouterId`/`targetRouterId`, so it can
  follow the router-offline rule. (`latencyProbeInterval` in the router
  configs is not read by 2.0.8; link costs are measured anyway.)
- PKI expiry (C12): healthreport's `pki` collector reads the chains the
  controller (8441) and both routers (8442) present in a TLS handshake from
  nuc. Root and intermediate: notice from 365 days (the email's Notices
  section), warn 90 (daily ntfy high), crit 30 (urgent). Controller and
  router leaves live one year and are renewed on every start, so they skip
  the notice stage and only warn/crit. Every chain must verify against the
  root pinned in the collector (a test keeps it equal to
  `ziti/pki/root-ca.crt`); a chain that does not is a crit.
- Rocky coexistence (C9), tested 2026-11-06 on mljr and nuc, one host at a
  time: `firewall-cmd --reload`, then `systemctl restart docker`. After
  each step: both routers online, the nuc-mljr link connected, Alloy and
  sshd reachable over Ziti from the laptop, containers reach the internet,
  Docker-published ports answer (mail 587 on mljr; Grafana, Kuma and
  VictoriaMetrics on nuc), no container unhealthy. Docker 29 runs with its
  firewalld backend and restores its rules after a reload by itself. A
  Docker restart took Docker down for 17-23 s; routers reconnected inside
  the router-offline alert's 5 minutes, so no alert fired.
- Data path (C6), tested 2026-11-06 with `scripts/ziti-c6-iperf.sh`. C6
  was redefined first: nas sits on the main FRITZ!Box, nuc and ugreen on a
  mesh repeater, so reaching nas through nuc's router would cross the mesh
  twice. Rule from this: every host that can run Ziti hosts its own
  services (its own router or tunneler); nuc's router is for LAN devices
  that cannot. Results (Tailscale/direct baseline measured back to back):
  - mljr to nas (Nextcloud upload), Go tunneler on nas: 94 %, circuit
    mljr router to nas only.
  - nas to mljr (download), Go tunneler: 53 %; C tunneler: hangs after
    connect; router on nas: 64 %. Plain TCP nas to mljr over the internet
    did 194 Mbit/s, so the line was not the limit. Router metrics showed
    the cause: the 4 MB xgress window full, ~450 retransmissions/s and
    duplicate acks, because nas's TCP send buffer (Unraid: BBR, 16 MB
    `tcp_wmem` max, unlimited `tcp_notsent_lowat`) queued seconds of data,
    so xgress saw a huge RTT and retransmitted data that was not lost.
  - Router on nas plus `net.ipv4.tcp_notsent_lowat=131072` on nas: 97-99 %
    (161-187 Mbit/s). Larger or smaller xgress windows and slower
    retransmit timers alone changed nothing; the Go tunneler with the same
    sysctl reached only 61 %.
  - LAN nas to ugreen (Go proxy on nas, Go host on ugreen, through nuc's
    router): 6-19 Mbit/s against 47-64 direct before the sysctl, 68 % with
    it; the mesh baseline swings 47-102 between runs. Never through mljr.
  Consequence for Phase 4/5: nas gets a router, not a tunneler, and the
  sysctl becomes part of nas's managed config.
- Visibility wired up: metrics, denials, enrolments, new-identity alert,
  "overlay down" alert.
- Tailscale fully unchanged.
- No time box: the PoC ends when every criterion below has a result, or
  when a must-criterion clearly fails.

Exit criteria, agreed 2026-11-05 before starting. **must** criteria block
Phase 4; the others decide tooling or shape later phases.

| # | Criterion | Pass if | Class |
|---|---|---|---|
| C1 | Enrol a new Linux host | ≤ 15 min from zero to a reachable service, following a written runbook | must |
| C2 | Controller DR | Snapshot restore onto a fresh mljr in ≤ 60 min; existing identities and routers reconnect via `ctrl.ziti.mljr.eu` without re-enrolment. Degraded mode on nuc: clients reconnect ≤ 15 min after the DNS flip | must |
| C3 | OpenTofu provider (`netfoundry/ziti` 0.0.5 or community `nenkoru/ziti`) | Services, service policies and edge-router policies can be created, updated and deleted against the self-hosted controller; `tofu plan` is empty after apply | decides tooling (fail: Go reconciler) |
| C4 | GitHub Actions OIDC | A CI job dials a Ziti service through an external JWT signer, with no long-lived secret | nice-to-have (fail: CI stays on Tailscale) |
| C5 | Cost on mljr | Controller and public router together use ≤ 400 MB RAM steady and ≤ 10 % of one core on average | must |
| C6 | Data path | External: mljr to nas over Ziti, with a Ziti endpoint on nas, reaches ≥ 90 % of the Tailscale path measured back to back, on a circuit mljr router to nas with no hop through nuc. LAN: nas to ugreen over Ziti reaches ≥ 75 % of the direct path measured back to back, with no traffic through mljr. `scripts/ziti-c6-iperf.sh` | must (a hairpin is an architecture failure) |
| C7 | WD armv7 tunneler | The 32-bit binary runs on wd_mycloud and hosts one service | informational, shapes Phase 5 |
| C8 | Laptop (Fedora Atomic) | Tunneler runs without rpm-ostree layering, survives a reboot, DNS intercept works with systemd-resolved | must (a container or sysext counts) |
| C9 | Rocky coexistence | Tunneler and router survive `firewall-cmd --reload` and a Docker restart; Docker networking still works | must |
| C10 | Short names (option B) | With the tunneler up, `ssh root@nuc` goes over Ziti via the `int.mljr.eu` search domain and a wildcard intercept. With it down, `nuc.int.mljr.eu` does not resolve. Resolution order next to MagicDNS during the parallel run is documented | must |
| C11 | Visibility | Ziti metrics in VictoriaMetrics; alerts for a router or overlay going down, a new identity enrolling, and policy denials | must |
| C12 | PKI | Root CA created offline (done 2026-11-05, docs/ZITI_PKI.md), only the intermediate on mljr, re-issuing the intermediate documented. A healthreport `pki` collector reports days left for the root, the intermediate and router certificates: info ≤ 365 days (daily email), warn ≤ 90 (daily ntfy, high), crit ≤ 30 (daily ntfy, urgent) | must |
| C13 | No regression | Tailscale and every existing service unchanged throughout | must |

**Rollback:** remove the controller, routers and tunnelers; nothing else
depends on them yet.
**Gate:** every must-criterion passes: go to Phase 4. Otherwise stop, or
change the design and repeat the failing criteria.

### Phase 4: Ziti production for mljr, nuc, ugreen

- Policy as code from `services_catalog` (OpenTofu, or the Go reconciler
  fallback).
- Move machine-to-machine traffic (exporters, backups, healthreport facts,
  Caddy upstreams from mljr to home services) onto Ziti services, one
  service at a time.
- CI: ephemeral Ziti identity per run. If that proves hard, keep Tailscale
  for CI until the final gate.
- Move the transport references left on `*.tail33930.ts.net` after Phase 2
  (SSH targets, `OPENVOX_HOSTS` and CI host lists, `reverse_proxy` and
  monitoring URLs, appliance proxy scripts) to `<host>.int.mljr.eu` intercept
  names, together with the service that carries them.
- Tailscale still in place as a fallback.

**Rollback:** per service, point the consumer back at the Tailscale
address.
**Gate:** all category-3 services work over Ziti with default-deny, and no
scraper, backup or webhook is silently broken.

### Phase 5: Appliances and OpenBolt push layer

- Enrol nas: tunneler (likely in Docker on Unraid) with identity and start
  hook on the flash drive, because the root filesystem is tmpfs.
- Enrol wd_mycloud: armv7 tunneler started from the clamAV boot hook (the
  crontab is wiped at every reboot), or a nuc-hosted hop if Phase 3 showed
  the tunneler can't run.
- Home Assistant: nuc-hosted Ziti services forwarding to its LAN address
  (SSH, 8123, scrape target), unless a Ziti add-on for Home Assistant OS
  proved viable in Phase 3.
- Test all three with a **real reboot**; earlier work found boot races only
  that way.
- Introduce OpenBolt from the laptop for bootstrap, enrolment and the
  appliance work that today runs as proxy `exec` on nuc's node block.
- Verify whether `apply()` in OpenBolt needs an OpenVox agent on the target.
  If it does (as Puppet Bolt did), appliances only get tasks, scripts and
  commands.
- Full DR drill: rebuild one host from a fresh OS using only the DR target
  inputs.

**Rollback:** appliances fall back to Tailscale and the existing proxy
`exec` pattern, which stays in the repo until this gate passes.
**Gate:** the DR drill passes, and option B measurably beats today's proxy
`exec` pattern on the metrics. If not, keep masterless OpenVox as it is.

### Phase 6: Identity provider PoC (Zitadel vs Authelia)

- Write pass/fail criteria first. Candidate wins: SCIM, passkeys, audit
  log, acting as Ziti's external JWT signer.
- Costs to weigh: Postgres in the DR chain, migrating the existing OIDC
  clients (Unraid, Sure, Actual, DefectDojo and others), AGPL-3.0.

**Rollback:** Authelia keeps running until cutover; revert the OIDC client
configs.
**Gate:** adopt Zitadel only on a clear win. Otherwise stay on Authelia.

### Phase 7: Host-level and LAN lateral-movement controls

- firewalld default-deny inbound per host, aligned with Ziti tags.
- **Docker bypasses firewalld** for published ports through its own
  iptables chains. Published ports must bind to `127.0.0.1` or the Ziti
  interface, or be filtered in the `DOCKER-USER` chain.
- Per-stack Docker networks, restricted container egress.
- Revisit the category-2 apps that stay public for now (kuma, forgejo,
  umami, projects, glucava): put each behind Authelia, or its Phase 6
  replacement, where public access is no longer needed.
- CI compliance gate lints exposure rules (extends the existing Checkov
  pattern), including "no published port on `0.0.0.0`".

**Rollback:** per host, revert the firewalld zone and the compose network
changes.
**Gate:** no shared Docker network spans unrelated stacks, default-deny
inbound is on every host OpenVox manages, and no container publishes on
`0.0.0.0` unintentionally.

### Phase 8: Final gate

- Confirm Tailscale's final role: break-glass only (expected), or remove it.
- Decide on an SSH CA (short-lived certs, `ziti-ssh`, or neither).
- Re-measure every metric against the Phase 0 baseline.
- Remove the proxy `exec` pattern and any Tailscale-only code paths that are
  no longer used.

## Metrics

Baselined in Phase 0 and re-measured at every gate.

**Quantitative**

- Lines of custom shell and exec glue in `openvox/`.
- Number of Go tools we maintain.
- Steps to onboard a new host.
- Steps to onboard a new service (target: one catalog entry plus one
  command).
- Wall time for a full check and a full apply.
- Ports and services reachable from any single host.
- LAN throughput nas to ugreen (must not regress materially).

**Qualitative**

- Can the whole access flow be explained on one page?
- Can a DR drill be done from the docs alone?
- Are failures easy to diagnose (a default-deny failure must not look like
  "service down")?
- How many distinct trust boundaries are there to reason about?

## Open items, deferred to PoC exit criteria on purpose

- Whether the wd_mycloud armv7 tunneler runs at all, and how nas enrols.
- Whether the Ziti OpenTofu provider covers the needed resources.
- Whether GitHub Actions OIDC works as a Ziti external JWT signer.
- How Caddy on mljr reaches backends over Ziti (tunneler intercept vs SDK).
- Whether `apply()` in OpenBolt needs an agent on the target.
- Effort estimate per phase, filled in at each gate.

## Research sources (2026-11-03)

- [OpenVox docs](https://docs.openvoxproject.org/), [OpenBolt repo](https://github.com/OpenVoxProject/openbolt), [first OpenBolt packages (Dec 2025)](https://voxpupuli.org/blog/2025/12/17/openbolt-packages-available/)
- [ZITADEL repo](https://github.com/zitadel/zitadel)
- [OpenZiti HA operations](https://openziti.io/docs/reference/ha/operations/), [ziti-tunnel-sdk-c](https://github.com/openziti/ziti-tunnel-sdk-c), [ziti-ssh](https://github.com/netfoundry/ziti-ssh), [HA advertise-address issue](https://github.com/openziti/ziti/issues/3588)
- [NetFoundry Terraform provider](https://support.netfoundry.io/hc/en-us/articles/41001773388429-Infrastructure-as-Code-IaC-with-Terraform-NetFoundry-Cloud-v8), [declarative Ziti config discussion](https://openziti.discourse.group/t/declarative-configuration-with-files/3393)
- [FRITZ!Box LAN guest access](https://fritz.com/en/apps/knowledge-base/FRITZ-Box-5530/949_Setting-up-LAN-guest-access-in-the-FRITZ-Box)
- Go IaC re-check: [go-ansible](https://go-ansible.github.io/), [gossh](https://github.com/krilor/gossh)
