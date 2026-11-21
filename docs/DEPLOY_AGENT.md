# Deploy agent: pull deploys with requests in git

Status: design and prototype, 2026-11-11. Follows from
docs/SPIKE_CONFIG_MGMT.md (OpenVox stays; deploys move from push over
SSH to pull by a small Go agent on each host).

## Why

`deploy.yml`, `openvox-drift.yml` and the PR live noop reached the hosts
as root over Tailscale SSH (until 2026-11-20). Tailscale goes (docs/ZERO_TRUST_PLAN.md), and
CI over Ziti is awkward (one ext-jwt signer per issuer, per-PR workflow
refs). With pull, CI needs no path to the hosts at all.

What must not change: a merge deploys nothing. A deploy happens when
someone asks for it, for one host at a time, as today with
`workflow_dispatch`.

## Flow

1. A PR is checked in CI without host access (catalog diff, see
   "Open").
2. The merge to `main` deploys nothing.
3. A deploy is a **request**: a commit on the branch `deploy/<host>`
   naming the `main` commit to apply. `deploy.yml` (dispatch, schedule,
   `repository_dispatch` from other repos) or the laptop creates it.
4. The agent on the host polls its branch, checks the request, applies
   the named commit with the same host-side apply as the laptop push,
   and reports the result.
5. The laptop push over Ziti (`openvox-sync.sh`) stays for bootstrap, DR
   and a broken agent.

## The request branch

`deploy/<host>` is an orphan branch: its history is only requests, one
commit each, linear, never rewritten. Its tree holds one file:

```json
// .deploy/request.json
{
  "id": "20261111T181502Z-42",
  "host": "nuc",
  "commit": "<sha of the main commit to apply>",
  "trigger": "workflow_dispatch",
  "service": "",
  "staging_services": "",
  "docker_prune": false,
  "reboot_if_needed": false
}
```

Requests are made with the GraphQL mutation `createCommitOnBranch`,
which GitHub signs with its web-flow key (checked 2026-11-11: user token,
`verified=true`, committer `GitHub <noreply@github.com>`). Commits made
with the REST git-data API are not signed. `expectedHeadOid` makes each
request a compare-and-swap: two requests at once cannot overwrite each
other.

Ruleset "Deploy request branches" (2026-11-21, GitHub settings, not in
this repo) blocks deletion and force-push on `deploy/*`, so the request
history is append-only; the repository admin role may bypass it. Who may
add a request is not restricted: on a personal repository GitHub Actions'
own token cannot be a ruleset bypass actor ("must be part of the ruleset
source or owner organization"), and a dedicated GitHub App for requests
was judged not worth its key. A request from any write token still has to
pass the checks below: GitHub-signed, for a commit on protected `main`.

The deployment history lives in git, not only in GitHub's Actions logs,
and moves with the repository. Moving to another server means another
signing key in the agent's keyring, nothing else.

## What the agent checks

A request is applied only when all hold:

1. The request commit is signed by a key in the agent's keyring (GitHub's
   web-flow keys, deployed by OpenVox).
2. `host` is this host, `id` is newer than the last request handled (no
   replay of an old request), and every parameter passes the same
   allowlist as `deploy.yml` today.
3. `commit` is reachable from `main` and signed by a key in the keyring.
   `main` is protected (PR required, no admin bypass), so this is what
   was reviewed and merged.
4. `commit` is the last applied commit or a descendant of it: rollback
   protection. A deliberate rollback is a revert on `main`, or the
   laptop push.

The signature on a commit covers its whole tree, so checking the target
commit is enough; earlier commits are not checked one by one (comin does
the same).

What this buys: whoever can create requests, including a stolen workflow
token, can only choose **when** an already merged commit is applied,
with allowed parameters. Never **what** is applied.

## The agent

- One static Go binary (`tools/cmd/deploy-agent`), go-git for fetch and
  signature checks: no `git` binary needed (ugreen has none).
- Polls `deploy/<host>` every 60 s (a cheap `ls-remote`; the repository
  is public, so no credentials).
- Applies **only on a new request**. It does not enforce on a timer, so
  a laptop push is not overwritten until the next deploy. A nightly
  noop reports drift instead (replaces `openvox-drift.yml`): in apply
  mode, daily at `roles::deploy_agent::drift_at` (03:17 host time), a
  noop of the last applied commit under the same host lock (a busy lock
  postpones it to the next poll). Only content/ensure/mode/owner/group
  value changes count, as in the workflow; `drift_ignore` lists expected
  ones (`backup_catalog.json` carries its compile time). It notifies once
  per new set of drifted resources, on a failed noop and when the drift
  is gone; metrics `homelab_deploy_drift_*`, healthreport kinds
  `deploy_drift` (warn), `deploy_drift_failed` (warn), `deploy_drift_stale`
  (crit, no check for 50 h on an apply agent).
- Runs `bash scripts/openvox-apply.sh <tree> apply` from the export:
  the same script `openvox-sync.sh` runs after uploading (PR #591:
  Forge modules, release + `production` symlink, `puppet apply`). One
  apply path for both. The script holds `/run/homelab-deploy.lock`, so
  a push and an agent apply never overlap.
- The request id is stored as "applying" before the apply runs. An
  agent that dies mid-apply (a reboot from `reboot_if_needed`) reports
  it as `interrupted` on start and does not run it again.
- **Weekly maintenance window** (`roles::deploy_agent::maintenance_window`,
  `DEPLOY_MAINTENANCE_WINDOW`, e.g. `Sun 01:00 30m`, host local time):
  once per window the agent applies its last applied commit with
  `OPENVOX_WEEKLY_MAINTENANCE=true`: `dnf upgrade`, docker prune, and the
  reboot when `needs-restarting -r` says so (`roles::base`). It starts
  only while the window is open (a host that was down waits a week),
  waits for a busy host lock, and is skipped while suspended. Result as
  mode `maintenance` (ntfy "Maintenance <commit> on <host>", metrics
  `homelab_deploy_maintenance_*`); an apply cut off by the reboot is
  reported as `interrupted` after it. nuc runs at 01:00, mljr at 01:30
  (the controller and public Caddy go down with it); ugreen has none (no
  `roles::base`, UGOS updates itself). Kuma's "Weekly host maintenance"
  window, Grafana's `weekly-maintenance` mute timing and ziti-notify's
  quiet window (`roles::ziti_notify::quiet`) cover Sun 01:00-02:00.
- A request turns the same maintenance on only with `docker_prune` or
  `reboot_if_needed`; trigger `schedule` no longer does.
- Suspend file (`/etc/homelab-deploy/suspend`): requests are seen and
  reported as suspended, not applied.
- A failed apply is reported and not retried; the next request or a
  laptop push follows.
- State in `/var/lib/homelab-deploy/`: last request id, last applied
  commit, outbox.
- **Ziti policy as code, on mljr only** (`roles::deploy_agent::ziti_tofu`,
  `DEPLOY_TOFU=scripts/ziti-tofu.sh`, 2026-11-20). After each successful
  apply the agent runs `ZITI_TOFU_LOCAL=1 bash scripts/ziti-tofu.sh auto`
  from the same export: OpenTofu for `ziti/tofu/` against the controller
  on `127.0.0.1:8440`, state key and admin password from
  `/opt/ziti-controller/.env`. Nothing of it reaches GitHub, whose logs
  are public. The merge to main is the approval for additions and
  in-place changes; a plan that deletes or replaces anything (a recreated
  identity loses its enrolment, a deleted policy cuts access) is **held**:
  not applied, notified as `Ziti tofu <commit> on mljr: held`, and
  applied by a person with `scripts/ziti-tofu.sh apply` after reading
  the plan. A plan without changes reports nothing; applied, held and
  failed runs are their own results (mode `ziti-tofu`), metrics
  `homelab_deploy_tofu_{last_run_timestamp_seconds,success}`. The daily
  drift check adds `scripts/ziti-tofu.sh check` (a plan): a change made
  on the controller by hand shows up as `Ziti tofu: <address> will be
  ...` drift lines in the same drift notification.

## Results and notifications

A failed deploy must always reach a person. No single channel can
promise that, so a lost notification has to be noticed.

1. **Outbox.** The agent writes each result to its outbox first, then
   sends it: ntfy (`/deployment`, as today), and when ntfy fails, mail
   with healthreport's account and relays (mail.mljr.eu, then Brevo). An entry is removed only after a channel accepted
   it, so an outage delays a notification but does not lose it.
2. **Expected versus seen.** The agent exports metrics:
   `homelab_deploy_last_poll_timestamp_seconds`,
   `homelab_deploy_request_seen{id}`,
   `homelab_deploy_last_result{id,result}` and the applied commit.
   They go to `/var/lib/node-textfile/homelab_deploy.prom`, which
   Alloy's textfile collector ships to VictoriaMetrics.
   Per result also run success, duration, resource changes, error lines
   and the last success time (`homelab_deploy_run_*` and friends, the
   values `deploy.yml` recorded for the push until 2026-11-20); the
   Grafana deploy panels prefer them over the push's `homelab_openvox_*`
   per host. healthreport's
   `deploy_agent` collector (another code path, its own email) compares
   them with the head request of `deploy/<host>` on GitHub: crit when
   the agent's metrics are missing or stale (10 min), a request goes
   unhandled for 15 minutes, or it ends failed, rejected or interrupted.
3. **Watching the watchers.** If ntfy, mail and healthreport fail
   together, only something outside the homelab notices: a HetrixTools
   heartbeat (cron job monitor) that the daily report pings once it
   reached a channel (PR #590). HetrixTools alerts when the pings stop.

`deploy.yml` creates requests and does not wait (fire and forget).

## deploy.yml after the change

- No Tailscale, no Ziti, no SSH. Permissions: `contents: write`.
- The validate job stays.
- `limit=all` creates one request per host in canary order (nuc, mljr,
  ugreen).
- `repository_dispatch` (`service-update`) creates a request for the
  service's host at the current `main`: a redeploy needs no new commit.

## Failure modes

| Case | Behaviour |
|---|---|
| Wrong commit merged | Nothing, until a request names it |
| Apply fails | Outbox result (ntfy, else mail); no retry loop |
| Agent dead or stuck | Poll metric goes stale, healthreport crit; laptop push still works |
| Broken agent release | Cannot deploy its own fix: the laptop push repairs it |
| GitHub down | No deploys; hosts keep running as they are |
| Request for an old commit | Refused (rollback protection), reported |
| GitHub rotates its key | New key into the keyring by OpenVox before the old one expires |

## Rollout

1. Prototype on the spike VMs (below).
2. Host-side apply script split out of `openvox-sync.sh`; the laptop
   push uses it (PR #591).
3. `roles::deploy_agent` (binary, unit, keyring, state dir); agent in
   noop-only mode on nuc next to the existing push.
4. `deploy.yml` creates requests for nuc; then mljr, ugreen. Its job
   `deploy-request` runs after the push (also when the push failed) for
   the hosts in `AGENT_HOSTS`, with the same commit and inputs, so the
   noop agent handles every real deploy too.
5. nuc's agent applies (`mode => 'apply'`); `deploy.yml` skips the push
   to the hosts in `AGENT_APPLY_HOSTS` in apply mode. Check mode, the PR
   noop and `openvox-drift.yml` still reach nuc over SSH. Then mljr and
   ugreen, each first in noop next to the push (#600), then applying as
   well (`roles::deploy_agent::mode` in their node data): since then the
   push in `deploy.yml` deploys no host in apply mode.
6. Remove the SSH steps and Tailscale from CI (2026-11-20): `deploy.yml`
   only creates requests (job `request`), the PR live noop is gone. Then
   `openvox-drift.yml` (the agents' drift check had run clean on all
   three hosts since #606), the `TS_OAUTH_*` secrets, the `tag:ci` ACL
   and the `production-check` environment.

## Open

- PR check without host access: the "Catalog diff" job compiles every
  host's catalog for base and head in VoxBox (`scripts/catalog-diff.sh`):
  facts from `openvox/ci/facts` (allowlisted, `scripts/catalog-facts.sh`),
  secrets as placeholders, and per `puppet:///` source the changed files.
  octocatalog-diff was dropped: no release since 2024 and its gem depends
  on `puppet`, which clashes with `openvox`. `deploy.yml` check mode (a
  run on a non-main branch) is the same diff from each host's deployed
  commit (`scripts/catalog-check.sh`) instead of a noop push. The PR
  live noop, the push path, `openvox-drift.yml` and Tailscale left CI on
  2026-11-20. A catalog diff does not catch runtime errors
  (a failing exec, a missing package); those surface as the agent's
  failure.

## Prototype (2026-11-11)

Code: `tools/internal/deployagent` (request, repo, agent, notify),
`tools/cmd/deploy-agent`. Unit tests run the agent against a local
repository with a generated signing key: success, redeploy of the same
commit, unsigned request, other host, replayed id, bad parameter, commit
not on main, unsigned target, rollback, suspend, failing apply, outbox
kept until a notifier succeeds.

Live run on spike-a (Rocky 10 VM on nuc), against GitHub, with
`spike/proto-main` as the protected branch (GitHub-signed commits made
through `createCommitOnBranch`) and the OpenVox spike slice as the tree:

| Step | Result |
|---|---|
| Request with the user token | signed (`verified=true`), applied |
| First poll (fetch of the whole history, 123 MB) | 16 s, of which apply 5 s |
| Poll with no new request | 0.36 s |
| Request from a workflow with `GITHUB_TOKEN` (`contents: write`) | signed (`verified=true`), applied, 5 s |
| Request for an older commit | rejected (rollback) |
| ntfy topic with an ACL (403) | result stayed in the outbox, sent on the next poll to `/deployment` |
| `--test-notify` on nuc with healthreport's account | ntfy, mail.mljr.eu and Brevo each delivered |

Findings:

- **Both tokens get signed commits** from `createCommitOnBranch`; the
  REST git-data API (`git/commits`) does not sign. Requests must use
  the GraphQL mutation.
- **`createCommitOnBranch` cannot set the exec bit**, so the agent runs
  the apply script with `/bin/sh`. That also avoids the
  `core.fileMode=false` trap.
- The keyring is GitHub's `https://github.com/web-flow.gpg` (two keys,
  the older one expired 2024-01-16); go-git verifies with it directly.
- Poll and apply are cheap: the agent adds seconds, `puppet apply`
  dominates.
- `tools/go.mod` gains go-git, and go.mod/go.sum are part of every
  committed service binary's source hash: merging the agent means
  rebuilding all of them (`scripts/service-binary.sh build`).
- The binary is 10 MB static (`CGO_ENABLED=0`), so ugreen (no git)
  works the same.

The prototype's leftovers went with the spike teardown (2026-11-21): the
branches `deploy/spike-a`, `spike/proto-main` and `spike/proto-gha`, and
spike-a itself with its agent, keyring and `/var/lib/homelab-deploy`.
