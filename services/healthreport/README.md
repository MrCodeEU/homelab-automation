# Health report agent

Daily homelab health report. Deterministic collectors gather facts, rules
assign severity, the run is diffed against the previous one, and the result is
pushed to ntfy and emailed.

The LLM writes prose and ranks the top three issues. **It never decides whether
something is a problem** — severity comes from `rules.yml` before the model is
called, and `llm.go` strips severity-like keys from the response and drops
any `observation_id` the run did not actually produce.

## Why the diff matters

Current state alone cannot tell you that a backup has been failing for four
days or that an error signature appeared today for the first time. Observation
ids are value-free (`<kind>.<subject>.<resource>`), so the same underlying
problem keeps the same identity as its value moves, and `new` / `reopened` /
`worsened` / `resolved` fall out of comparing runs.

## Layout

Source lives in `tools/internal/healthreport/` (compiled into the
`healthreport` binary committed here, same pattern as every other Go-ported
service — see `tools/cmd/healthreport/main.go`).

| Path | Purpose |
|---|---|
| `tools/internal/healthreport/collectors/` | one file per data source, each independently runnable |
| `tools/internal/healthreport/severity.go` | applies `rules.yml`; the only place severity is decided |
| `tools/internal/healthreport/diff.go` | run-over-run diff and the long-lived `seen/` state |
| `tools/internal/healthreport/llm.go` | Ollama load → generate → unload, with validation |
| `tools/internal/healthreport/render.go`, `render_html.go`, `deliver.go` | Markdown/HTML report, ntfy push, email |
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

The container is one-shot. Its compose default command is `--noop`, so the
deploy step (`docker compose up -d`) starts it, it prints its configuration and
exits without collecting or sending anything. A systemd timer installed by
`hooks/post-deploy.sh` owns the real schedule and passes `--send` explicitly.

A compose `profiles:` entry would be the more obvious way to keep the deploy
from starting it, but `docker compose up -d` fails with "no service selected"
when every service in a project is profiled, which breaks the services role.

To trigger a full run by hand, without waiting for the timer:

```bash
# on nuc — exactly what the timer does, including delivery
systemctl start homelab-healthreport.service
journalctl -u homelab-healthreport.service -f

# or directly, e.g. to a test topic first
cd /opt/healthreport && docker compose run --rm healthreport \
  --send --ntfy-topic homelab-health-test
```

```bash
# one collector, no state, no delivery
docker compose run --rm healthreport \
  --collect-only --collector host_metrics --pretty

# full run: collect, classify, diff, render. Prints Markdown, sends nothing,
# does not rotate state.
docker compose run --rm healthreport --dry-run

# the real thing (what the timer runs)
docker compose run --rm healthreport --send

# delivery smoke test on a throwaway topic
docker compose run --rm healthreport \
  --send --ntfy-topic homelab-health-test --email-to you@example.com
```

Failure paths, all of which must still produce a report and exit 0:

```bash
# Ollama unreachable  -> llm_status=unavailable
docker compose run --rm healthreport \
  --dry-run --ollama-url http://127.0.0.1:1

# model returns junk   -> llm_status=degraded_invalid
docker compose run --rm healthreport \
  --dry-run --llm-fixture /path/to/bad-llm.json
```

Offline diff against two saved facts.json snapshots, no network at all:

```bash
docker compose run --rm healthreport \
  --diff-only --facts /state/history/facts-YYYYMMDD.json \
              --facts-previous /state/history/facts-YYYYMMDD.json
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

`/var/lib/healthreport/state` on nuc:

- `facts-latest.json`, `facts-previous.json` — the two runs being compared
- `history/facts-YYYYMMDD.json` — 30 days
- `seen/observations.json` — first/last seen per observation id; this is what
  makes "since 2026-07-21" and SMART sector trends possible

`/var/lib/healthreport/ssh/id_ed25519` is the facts-endpoint key. It is
forced-command restricted on the remote side, but keep it 0600 and out of the
backup set regardless.
