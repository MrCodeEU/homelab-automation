# Health report agent

Daily homelab health report. Deterministic collectors gather facts, rules
assign severity, the run is diffed against the previous one, and the result is
pushed to ntfy and emailed.

The LLM writes prose and ranks the top three issues. **It never decides whether
something is a problem** — severity comes from `rules.yml` before the model is
called, and `app/llm.py` strips severity-like keys from the response and drops
any `observation_id` the run did not actually produce.

## Why the diff matters

Current state alone cannot tell you that a backup has been failing for four
days or that an error signature appeared today for the first time. Observation
ids are value-free (`<kind>.<subject>.<resource>`), so the same underlying
problem keeps the same identity as its value moves, and `new` / `reopened` /
`worsened` / `resolved` fall out of comparing runs.

## Layout

| Path | Purpose |
|---|---|
| `app/collectors/` | one module per data source, each independently runnable |
| `app/severity.py` | applies `rules.yml`; the only place severity is decided |
| `app/diff.py` | run-over-run diff and the long-lived `seen/` state |
| `app/llm.py` | Ollama load → generate → unload, with validation |
| `app/render.py`, `app/deliver.py` | Markdown report, ntfy push, email |
| `rules.yml` | thresholds — tune these, not the code |

## Data sources

Most facts are HTTP calls to services already running on nuc:

- **VictoriaMetrics** (`:19090`) — disk, memory, load, steal, reboots, failed
  units, container inventory drift, restart loops, OOM kills
- **Loki** (`:3100`) — new error signatures, error rates, auth failures, 5xx
- **Uptime Kuma** (`:3001/metrics`) — monitor state and certificate expiry
- **GitHub API** — workflow conclusions, Dependabot and code scanning alerts
  across every repo the account owns
- **ntfy** — replays Diun's `docker-updates` topic instead of polling registries

Anything not reachable over the network — CrowdSec's loopback-bound LAPI, the
nftables ruleset, Unraid array/SMART state — comes from a read-only script
behind an SSH key restricted to that one command
(`ansible/roles/host-facts-endpoint`). No new listening ports.

## Running it

The container is one-shot and sits behind the `cron` compose profile, so a
deploy never starts it. A systemd timer installed by `hooks/post-deploy.sh`
owns the schedule.

```bash
# one collector, no state, no delivery
docker compose --profile cron run --rm healthreport \
  --collect-only --collector host_metrics --pretty

# full run: collect, classify, diff, render. Prints Markdown, sends nothing,
# does not rotate state.
docker compose --profile cron run --rm healthreport --dry-run

# the real thing (what the timer runs)
docker compose --profile cron run --rm healthreport --send

# delivery smoke test on a throwaway topic
docker compose --profile cron run --rm healthreport \
  --send --ntfy-topic homelab-health-test --email-to you@example.com
```

Failure paths, all of which must still produce a report and exit 0:

```bash
# Ollama unreachable  -> llm_status=unavailable
docker compose --profile cron run --rm healthreport \
  --dry-run --ollama-url http://127.0.0.1:1

# model returns junk   -> llm_status=degraded_invalid
docker compose --profile cron run --rm healthreport \
  --dry-run --llm-fixture tests/fixtures/bad-llm.json
```

Offline diff against fixtures, no network at all:

```bash
docker compose --profile cron run --rm healthreport \
  --diff-only --facts tests/fixtures/facts-day2.json \
              --facts-previous tests/fixtures/facts-day1.json
```

Unit tests (no network, no container):

```bash
make test-healthreport
```

## Tuning

Edit `rules.yml`, not the collectors. Every threshold there was chosen against
one day of real data and should be revisited after a week — the goal is that a
green report means green, and a non-green report is worth reading. If a
finding is noise, either raise its threshold or move its rule to `new_only`.

## State

`/opt/healthreport/state` on nuc:

- `facts-latest.json`, `facts-previous.json` — the two runs being compared
- `history/facts-YYYYMMDD.json` — 30 days
- `seen/observations.json` — first/last seen per observation id; this is what
  makes "since 2026-07-21" and SMART sector trends possible

`/opt/healthreport/ssh/id_ed25519` is the facts-endpoint key. It is
forced-command restricted on the remote side, but keep it 0600 and out of the
backup set regardless.
