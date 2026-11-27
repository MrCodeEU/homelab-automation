# Access flow on one page

Who reaches what, and what stops everyone else. The reasons and the
history are in [ZERO_TRUST_PLAN.md](ZERO_TRUST_PLAN.md); this page is the
picture. Written for Phase 8 of that plan (2026-11-27).

```
 browser, phone, family                       you, on the laptop
          |                                           |
          | https://<app>.mljr.eu                     | ziti-edge-tunnel
          v                                           | (login: Authelia, external JWT signer)
   mljr: Caddy  ------ Authelia (OIDC, forward auth)  |
   CrowdSec bouncer           ^                       |
          |                   +-- opkssh login -------+--> ssh root@<host>.ziti
          | dials <name>.<host>.int.mljr.eu           |    ZAC (read-only) at ziti.mljr.eu
          v                                           v
   +-------------------- OpenZiti overlay (default deny) --------------------+
   | controller + public router on mljr, routers on nuc, nas, ugreen           |
   | policy as code (ziti/tofu, OpenTofu), identities are disposable           |
   +-----+------------------+------------------+------------------+-----------+
         |                  |                  |                  |
        mljr               nuc               ugreen         nas, wd_mycloud,
   (VPS, public)      (home, apps)         (home, backup)   Home Assistant (appliances)
```

## Who gets in, and how

| Who | Path | What proves it |
|---|---|---|
| Browser, phone, family | Public vhost on mljr's Caddy. Per app: its own login, or Authelia in front (forward auth or OIDC). | The app's login, or Authelia (a second factor for paperless, the Ziti console and cockpit; one factor for the rest). No Ziti client needed. |
| You, admin | Laptop tunneler, then `ssh root@<host>.ziti` (`root@nas-ssh.ziti` for nas). | Authelia login for the overlay, `opkssh login` for SSH (about daily). |
| Hosts and containers (machine to machine) | Proxy sidecars on `127.0.0.1` with their own Ziti identity (`m2m-<host>`), one service per use. | A Ziti identity per host, scoped by policy to named services. |
| Deploys | GitHub Actions writes a signed request to `deploy/<host>`; each host's agent pulls and applies it. | The signature. CI holds no host credential and no inbound path exists. |
| Appliances | nas has its own router, wd_mycloud runs a tunneler, Home Assistant is hosted by nuc's router. Management SSH runs over Ziti from nuc. | A key per appliance, usable only from the host that manages it (`from=`, no forwarding). |

## What stops everyone else

1. **Ziti policy.** Default deny. A service exists for a pair of identities
   or none. Policy is generated from `services_catalog`, reviewed as a pull
   request, applied by `scripts/ziti-tofu.sh`, and drift is checked.
2. **Host firewall.** nuc: firewalld, the LAN reaches ssh and the router
   only, and Docker's forwarded ports are dropped (`StrictForwardPorts`).
   nas and ugreen: the `HOMELAB-INPUT` chain (log mode first, then default
   deny). Containers get their own rules: published ports bind to
   `127.0.0.1`, databases sit on internal networks, and the LAN and the
   host are off limits to containers except listed exceptions
   (`HOMELAB-FORWARD`, the container section of `HOMELAB-INPUT`).
3. **Authelia.** Forward auth, OIDC clients and the access rules live in
   the repo (`roles::authelia`, `authelia_oidc_clients`); the rules ask for
   a second factor where the app is root-level or holds personal documents.
4. **The app's own login.** Where an app has one (git, Home Assistant,
   photos), it stays on.

Three of the four boundaries are in git (Ziti policy, firewall rules,
Authelia rules); the fourth is each app's own accounts.

## When something does not work

- A dial that Ziti refuses names the service in the error. `ziti edge
  policy-advisor services` says which identity may reach it; the read-only
  console at `ziti.mljr.eu` and the Grafana mesh map show routers, circuits
  and identities.
- A firewall drop in log mode is a `homelab-in:`, `homelab-fwd:` or
  `homelab-ctr:` line in Loki. In enforce mode a container's connection is
  rejected at once (`connection refused`) and still logged.
- SSH refused: is `opkssh login` older than a day, is the overlay up, is
  the tunneler running? Then [BREAKGLASS.md](BREAKGLASS.md).

## When the overlay or the IdP is gone

Break-glass keys (two YubiKeys, one software key in Bitwarden) work against
the hosts' own sshd, from the LAN or the public break-glass port on mljr:
[BREAKGLASS.md](BREAKGLASS.md). Rebuilding a host from nothing, with the
order of steps and what must exist outside the lab:
[DISASTER_RECOVERY.md](DISASTER_RECOVERY.md); the controller and its PKI:
[ZITI_DR.md](ZITI_DR.md), [ZITI_PKI.md](ZITI_PKI.md).

## What is left of Tailscale

`tailscaled` still runs on the hosts as a safety net and carries no
traffic (checked 2026-11-26). It is removed at the end of the plan.
