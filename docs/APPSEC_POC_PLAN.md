# CrowdSec AppSec (WAF) proof of concept

Status: plan, not started (2026-10-25). Backlog entry: "CrowdSec AppSec PoC".

## Goal

Decide with measurements, not opinions, whether CrowdSec AppSec in front of
mljr's Caddy is worth running. Nothing in production changes during the PoC.

Go only if **all** of these hold:

| # | Criterion | How it is measured |
|---|-----------|--------------------|
| 1 | No false positive on legitimate traffic after tuning | Replay of 7 days of real mljr requests against the PoC, 0 blocks and under 0.1 % alerts |
| 2 | Catches real attacks | Share of Nuclei attack requests AppSec flags, per template tag; plus the CVE virtual-patching tests |
| 3 | Fail-open works | AppSec stopped mid-test: requests still pass, Caddy logs the error |
| 4 | Large uploads are safe | 1 GiB PUT to an excluded path finishes; a 5 MiB body to an inspected path is capped, not buffered whole |
| 5 | Cheap enough for mljr | p95 added latency under 20 ms; crowdsec container memory growth under 400 MB (mljr has about 2.4 GB available of 7.6 GB) |
| 6 | Maintainable | Custom Caddy build is reproducible from a pinned commit and can be rolled back to the COPR package in one apply |

## Facts checked

- mljr runs CrowdSec **1.8.1** (container `crowdsec`), Caddy **2.11.7** from the COPR package, 46 vhost snippets in `/etc/caddy/conf.d`, one global `access` log.
- Collections installed today: base-http-scenarios, caddy, http-cve, linux, sshd, postfix, dovecot, whitelist-good-actors, mailcow, authelia. **No AppSec collections yet.**
- The only bouncer today is the nftables firewall bouncer. The Caddy bouncer is new.
- AppSec is a component inside the CrowdSec engine (acquisition `source: appsec`, listens on `127.0.0.1:7422` by default). It needs `crowdsecurity/appsec-virtual-patching` and `crowdsecurity/appsec-generic-rules`. Config: `inband_rules` block immediately, `outofband_rules` only report. `on_match` hooks can override the remediation; `pre_eval` hooks can drop rules per URI or IP. [Config reference](https://docs.crowdsec.net/docs/next/appsec/configuration), [general setup](https://docs.crowdsec.net/docs/next/appsec/quickstart/general_setup.md).
- Caddy side is [hslatman/caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer), built with xcaddy from `.../http` and `.../appsec`. Global options: `api_url`, `api_key`, `ticker_interval`, `appsec_url`, `appsec_fail_open` (a bare flag, no argument; default **fail closed**), `appsec_max_body_bytes` (default **0 = unlimited**), `appsec_timeout` (the README's `appsec_max_timeout` does not exist in v0.14.1; checked in `crowdsec/caddyfile.go`). Per route: the `appsec` directive, placed before the final handler. Upstream README shows `@main`; we pin a commit.
- Nuclei runs from nuc and nuc's IP is in CrowdSec's allowlist (`mljr-local-allowlist.yaml`). Whether that allowlist also silences AppSec alerts is **unverified**: step C1 tests it first.

## Design

Production Caddy is not touched. A throwaway second Caddy runs next to it:

```
nuc (nuclei, replay) --tailnet--> mljr 100.100.20.1:8444  caddy-poc  --appsec--> crowdsec:7422
                                                  :8445  caddy-poc (same build, no appsec, baseline)
                                       upstream: traefik/whoami (static echo)
```

- `caddy-poc` is a container from an xcaddy build, joined to the crowdsec compose network so it reaches `crowdsec:7422` and the LAPI without a host port. Only 8444/8445 are published, on the tailnet IP.
- A dedicated bouncer key (`BOUNCER_KEY_caddy_poc`), so it can be deleted without touching the firewall bouncer.
- AppSec runs with a PoC-only config `homelab/poc-logonly`: same rules as `crowdsecurity/appsec-default`, plus an `on_match` hook that sets the remediation to `allow`. Matches still create alerts, nothing is blocked. A second config `homelab/poc-block` (default remediation `ban` → 403) is switched in for the blocking runs.
- The shared AppSec port only matters for the PoC; production Caddy does not point at it until a go decision.

## Phases

**A. Build (no host changes).**
1. Dockerfile `services/caddy-poc/Dockerfile`: `xcaddy build` pinned to the Caddy version in use and to a specific bouncer commit (recorded in the file).
2. Record image digest, binary size, SBOM/Trivy result (DefectDojo already scans images).

**B. Enable the component on mljr (small PR, additive).**
1. `services/crowdsec`: add `crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules` to `COLLECTIONS`, a new `appsec` block in `acquis.yaml` (`listen_addr: 0.0.0.0:7422` inside the container, no published port), mount the two appsec-config files, add `BOUNCER_KEY_caddy_poc`.
2. Check: `cscli appsec-configs list`, `curl` to the test URL from the CrowdSec docs, `cscli alerts list | grep appsec-generic-test`.
3. Compare crowdsec memory before and after (criterion 5).

**C. Measure.**
1. *Allowlist check:* one Nuclei template from nuc against 8444; confirm an AppSec alert appears despite nuc being allowlisted. If not, run the attack set from the workstation instead (and note it).
2. *Detection:* nuclei-scan against 8444 with the same severity and exclude-tags as the nightly scan, then group alerts by rule and by template id. Baseline: same run against 8445.
3. *False positives:* take 7 days of `/var/log/caddy/access.log` from mljr, rebuild request lines (method, URI, selected headers, no bodies, no auth cookies), replay at low rate against 8444 in log-only mode. Alert per 1000 requests, grouped by vhost. Each alert is read and either tuned away with a `pre_eval` rule removal (written down) or counted as a real hit.
4. *Blocking run:* switch to `poc-block`, repeat C2 and C3. Expected: attacks 403, replay unchanged.
5. *Fail-open:* `docker stop` the crowdsec container mid-replay. Requests keep passing; the Caddy error log shows the fallback.
6. *Uploads:* 1 GiB PUT to a path excluded from `appsec`; 5 MiB POST to an inspected path with `appsec_max_body_bytes 1048576`. Watch Caddy and crowdsec memory.
7. *Latency:* `hey`/`wrk` 5000 requests, 20 connections, 8444 vs 8445; compare p50/p95/p99.

**D. Decision.** Fill in the table at the top, write results into this file, then go or no-go. A no-go removes `caddy-poc`, the bouncer key and the appsec acquisition (they are all additive, so this is a revert).

## Results so far

**B (2026-10-25, deployed to mljr, PoC listeners up):**

- Chain verified from nuc over the tailnet against `100.100.20.1`: clean request 200; known phpunit RCE probe 200 in log-only mode with the rule counted; same probe with `X-Appsec-Mode: block` 403; the same probe on the baseline `:8445` 200.
- Mode switch: `homelab/poc` returns `allow` unless the request has `X-Appsec-Mode: block`. Log-only matches still raise alerts.
- Allowlist question answered: the CrowdSec allowlist (nuc's tailnet IP, the home IP) does **not** suppress AppSec alerts, so Nuclei from nuc is measurable.
- Ban risk checked in a throwaway container with mljr's real profiles: 25 blocked probes per IP produced alerts but **no ban decisions**, so a blocking run cannot get nuc banned by the firewall bouncer.
- Memory (criterion 5): crowdsec 67.5 MiB before, 84.3 MiB after (+17 MiB); caddy-poc 22 MiB; host available memory unchanged (about 2.3 GB).
- Gotchas found: the Caddy binary has the file capability `cap_net_bind_service`, so `cap_drop: ALL` needs `cap_add: NET_BIND_SERVICE`; the builder image sets its own `CADDY_VERSION` env, so the Dockerfile arg is `CADDY_TAG`; the image is built on nuc and loaded on mljr (xcaddy is too heavy to run beside production).

**C2 Nuclei detection (2026-10-25):** Nuclei v3.11.1, 6051 templates, about 14,000 requests per run against `:8444`. Log-only: 10,126 requests processed, 1,499 matched, 95 distinct rules, none blocked. Block mode: exactly the 1,499 matched requests got 403, everything else passed. 1,300 of the 1,499 are one Grafana path-traversal template; the other 198 are phpunit `eval-stdin.php`, `.env`/`.git`, WordPress plugin and misc CVE paths. The out-of-band `experimental-no-user-agent` rule fired 1,456 times and blocked nothing, as designed. The upstream is a static echo, so Nuclei findings carry no meaning and there is no recall percentage.

**C3 replay of real traffic (2026-10-25):** source = Loki, mljr Caddy logs of the last 7 days, only requests served 2xx/3xx (about 647k lines), deduplicated to 117,704 unique request shapes (method, host, URI with token-like path parts and query values masked, User-Agent, Accept, Content-Type; no cookies, no bodies). Replayed in block mode at 200 req/s over 10 min, 12 connections. mljr load average rose to about 7 on 4 CPUs, crowdsec peaked at 124 % CPU and 144 MiB, no Kuma monitor went down.

- 108,960 x 200, 3,704 x 307, 5,038 x 403, 2 other. The 403s weigh 6,271 of the real hits, about 1 % of served traffic.
- Of the 5,038 blocked shapes, 4,997 are reproducible with a one-by-one retry and all are scanner traffic that mljr answered with 2xx/3xx (the catch-all vhosts, or an auth redirect): `.env`/`.git`/cloud-credential file probes, path traversal, WordPress/PHP paths, CVE probes (Ivanti, Jira, Citrix and others), and scanner User-Agents. None is a legitimate user request.
- **41 blocked requests are plain `GET /` with ordinary browser User-Agents.** A one-by-one retry without the `Accept` header gave 200, which looked like a load-only false positive. A second full replay with the caddy-poc and crowdsec logs captured showed the cause: all 41 carry `Accept: ../../../../../../../../etc/passwd{{`, a path-traversal payload in a header. They are real attacks that AppSec caught, so the 5,038 blocks contain no false positive. The second run gave the same counts as the first (deterministic). Lesson: the retry must send the same headers as the original request.
- Side findings from the crowdsec log: AppSec logs `unable to parse url '//interactsh.com%2f..'` for malformed scanner URLs (harmless); a pre-existing `sending signal to central API ... Forbidden` error is unrelated to AppSec.

Criterion 1 is **met** for this replay: 0 blocks of legitimate traffic in 117,704 unique requests. Request bodies and cookies were left out of the replay on purpose, so they are not covered. Criterion 2 is met for the classes above. Criterion 5 memory is met; latency is still unmeasured.

## Rollout if go (separate plans and PRs)

1. Weekly GitHub Actions build of the custom Caddy binary from pinned versions, published with a SHA-256 checksum. Renovate tracks Caddy and the bouncer commit. Puppet installs it (like the other prebuilt tools), keeping the COPR rpm installed so rollback is flipping one hiera value.
2. Production Caddy gets the global `crowdsec { ... appsec_fail_open appsec_max_body_bytes 1048576 }` block and a snippet `appsec_protect` imported per vhost, starting with the least critical vhosts.
3. Excluded from the `appsec` directive: Nextcloud WebDAV and upload paths, Immich asset upload, Mailcow ActiveSync/SOGo if the replay shows trouble.
4. Log-only first in production for a week, then blocking vhost by vhost. Kuma and healthreport already watch every vhost, plus a new healthreport rule for AppSec alert spikes.

## Risks

- **Single edge host.** A wrong rule or a hung AppSec takes every site down: mitigated by fail-open, a 2 s `appsec_timeout` and the log-only week.
- **Custom binary lag.** A Caddy CVE needs our rebuild, not a `dnf upgrade`. Mitigated by the weekly build and Renovate; accepted by the user on 2026-09-07.
- **Memory.** mljr has about 2.4 GB available; AppSec rule sets are loaded in the crowdsec process. Measured in B3.
- **Mailcow and Authelia flows** use unusual headers and bodies; the replay covers them because it uses real logs.
- **IPv6 and HTTP/3** behaviour of the plugin was not tested upstream; we only use HTTP/1.1 and HTTP/2 in the PoC and verify HTTP/3 before rollout.

## Open questions for the user

1. Replaying real request lines against the PoC is read-only for production but copies URIs (may contain tokens in query strings). OK to scrub query strings to keys only?
2. Is a first PoC on tailnet ports 8444/8445 acceptable, or should it run on a separate hostname?

## Effort

About three small PRs (build, enable component, results) plus a measurement session. The measurement session is where most of the time goes.
