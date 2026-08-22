"""Log-derived facts from Loki.

The valuable signal is not the error *rate* - that is noisy and mostly
constant. It is the appearance of an error *signature* that has never been
seen before. Signatures are normalized (numbers, hashes, IPs, UUIDs masked) so
that a thousand variations of the same message collapse into one identity.
"""

import re
import time
from collections import Counter

from ..model import CollectorResult, Observation, is_ephemeral
from .base import collector, http_get

ERROR_PATTERN = "(?i)(error|fatal|panic|traceback|exception)"

# Structured logs carry an error field on success too: Caddy access logs all
# contain `error=<nil>`, which made every served request look like an error and
# inflated the daily count into the tens of thousands. Drop the "no error"
# idioms before counting.
#
# mailcow's ofelia scheduler logs its own idiom - "failed: false, skipped:
# false, error: none" - on every single successful cron job run (colon-space,
# not the =<nil>/JSON-null shapes above), which alone produced 10k+ "error"
# lines/24h out of routine housekeeping. (?i) since ofelia's "none" is
# lowercase but other emitters may differ.
NOT_ERROR_PATTERN = r'(?i)(error=<nil>|error=null|"error":null|"error":""|err=<nil>|error=\s*$|error:\s*none\b)'

# Loki's querier echoes the query text into its own logs. Since these queries
# contain the word "error", every run manufactures the errors the next run
# finds - a feedback loop that grows without bound. Exclude the query engine's
# own chatter.
SELF_LOG_PATTERN = r'(component=querier|component=ingester|caller=(metrics|engine)\.go)'

# A signature must recur this often within the sample before it becomes an
# observation, and only this many are reported per run.
MIN_SIGNATURE_COUNT = 10
MAX_SIGNATURES = 15

DOCKER_ERRORS = '{job="docker"} |~ `%s` !~ `%s` !~ `%s`' % (
    ERROR_PATTERN, NOT_ERROR_PATTERN, SELF_LOG_PATTERN,
)

# Order matters: mask the most specific shapes first.
NORMALIZERS = [
    # ANSI colour codes must go first, and not only because they are ugly in a
    # notification. A sequence like `\x1b[2m` ends in a word character, so a
    # timestamp glued straight to it ("\x1b[2m2026-07-29T08:05:31") has no word
    # boundary in front of the digits and the <ts> rule below silently fails to
    # match. The timestamp then falls through to the generic <n> rule, every
    # run produces a different signature for the same event, and one four-line
    # error block from bichon became four separate "new signature" warnings.
    (re.compile(r"\x1b\[[0-9;]*[A-Za-z]"), ""),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<uuid>"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"), "<ip>"),
    (re.compile(r"\b[0-9a-f]{16,}\b", re.I), "<hash>"),
    (re.compile(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\S*"), "<ts>"),
    # Any slash-bearing token is a path, digits or not. The previous rule
    # required a digit, so syncthing's per-file "Failed to sync" lines
    # (thesis/main.aux, thesis/main.pdf, ...) each became a distinct signature
    # and one stuck sync produced five separate warnings.
    (re.compile(r"[\w.\-]*/[\w./\-]+"), "<path>"),
    (re.compile(r"\b\d+\b"), "<n>"),
    (re.compile(r"\s+"), " "),
]


def normalize(line: str) -> str:
    text = line.strip()
    for pattern, replacement in NORMALIZERS:
        text = pattern.sub(replacement, text)
    return text[:200]


WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
WINDOW_RE = re.compile(
    r"^\s*(?P<day>daily|mon|tue|wed|thu|fri|sat|sun)\s+"
    r"(?P<from_h>\d{1,2}):(?P<from_m>\d{2})\s*-\s*"
    r"(?P<to_h>\d{1,2}):(?P<to_m>\d{2})\s*$",
    re.I,
)


def parse_windows(specs):
    """Parse "sun 05:00-08:00" strings into (day_index, start_min, end_min).

    day_index is None for `daily`. Unparseable entries are dropped rather than
    raising: a typo in one window must not take the whole report down, and the
    evidence carries the raw strings so a window that never matches is visible.
    """
    out = []
    for spec in specs or []:
        match = WINDOW_RE.match(spec)
        if not match:
            continue
        day = match.group("day").lower()
        start = int(match.group("from_h")) * 60 + int(match.group("from_m"))
        end = int(match.group("to_h")) * 60 + int(match.group("to_m"))
        out.append((None if day == "daily" else WEEKDAYS.index(day), start, end))
    return out


def in_window(when, windows) -> bool:
    """Is this local-time struct inside any window?

    Windows that wrap past midnight (23:00-01:00) are handled by treating the
    range as two: the day it starts on and the small hours of the next one. The
    weekday of a wrapping window is the day it *starts*.
    """
    minute = when.tm_hour * 60 + when.tm_min
    weekday = when.tm_wday
    for day, start, end in windows:
        if start <= end:
            if (day is None or day == weekday) and start <= minute < end:
                return True
            continue
        # Wraps midnight: before the end means it belongs to the previous day.
        if (day is None or day == weekday) and minute >= start:
            return True
        previous_day = (weekday - 1) % 7
        if (day is None or day == previous_day) and minute < end:
            return True
    return False


def split_maintenance(series, windows):
    """Split [(unix_ts, value)] into (kept, suppressed) by maintenance window.

    A bucket produced by `count_over_time([1h])` at timestamp T covers the hour
    ending at T, so it is judged by the hour it *starts*: a window at 05:00-08:00
    should swallow the bucket stamped 06:00, which covers 05:00-06:00.
    """
    if not windows:
        return list(series), []
    kept, suppressed = [], []
    for ts, value in series:
        started = time.localtime(ts - 3600)
        (suppressed if in_window(started, windows) else kept).append((ts, value))
    return kept, suppressed


def _hour_label(ts) -> str:
    if not ts:
        return "n/a"
    return time.strftime("%a %H:%M", time.localtime(ts))


def query_matrix(config, logql, hours, step=3600):
    """Range query returning [(labels, [(unix_ts, value), ...])].

    Unlike query_range below this expects a *metric* query, so Loki returns a
    matrix of samples rather than log lines - no `limit` truncation to worry
    about.
    """
    end = time.time()
    start = end - hours * 3600
    response = http_get(
        config.loki_url.rstrip("/") + "/loki/api/v1/query_range",
        params={
            "query": logql,
            "start": "%d" % int(start * 1e9),
            "end": "%d" % int(end * 1e9),
            "step": "%d" % int(step),
        },
        timeout=60,
    )
    payload = response.json()
    if payload.get("status") != "success":
        raise RuntimeError("loki query failed: %s" % payload)
    out = []
    for series in payload.get("data", {}).get("result", []):
        points = []
        for pair in series.get("values", []):
            try:
                points.append((int(float(pair[0])), float(pair[1])))
            except (IndexError, TypeError, ValueError):
                continue
        out.append((series.get("metric", {}), points))
    return out


def query_instant(config, logql):
    """Instant query, for aggregations.

    Counting the entries returned by query_range is wrong: the result is
    silently truncated at `limit`, so a busy service reports exactly `limit`
    every day and the number is meaningless. count_over_time is evaluated
    server-side over the whole window.
    """
    response = http_get(
        config.loki_url.rstrip("/") + "/loki/api/v1/query",
        params={"query": logql},
        timeout=60,
    )
    payload = response.json()
    if payload.get("status") != "success":
        raise RuntimeError("loki query failed: %s" % payload)
    out = []
    for series in payload.get("data", {}).get("result", []):
        try:
            out.append((series.get("metric", {}), float(series["value"][1])))
        except (KeyError, IndexError, ValueError):
            continue
    return out


def query_range(config, logql, hours, limit=5000):
    end = time.time()
    start = end - hours * 3600
    response = http_get(
        config.loki_url.rstrip("/") + "/loki/api/v1/query_range",
        params={
            "query": logql,
            "start": "%d" % int(start * 1e9),
            "end": "%d" % int(end * 1e9),
            "limit": limit,
            "direction": "backward",
        },
        timeout=60,
    )
    payload = response.json()
    if payload.get("status") != "success":
        raise RuntimeError("loki query failed: %s" % payload)
    return payload.get("data", {}).get("result", [])


@collector("logs")
def collect(config, rules):
    result = CollectorResult(name="logs")
    obs = result.observations
    hours = config.lookback_hours

    logql = DOCKER_ERRORS

    # Accurate totals, evaluated server-side over the whole window.
    per_container = Counter()
    count_q = 'sum by (host, container) (count_over_time(%s [%dh]))' % (DOCKER_ERRORS, hours)
    for metric, value in query_instant(config, count_q):
        host = metric.get("host") or metric.get("instance") or "unknown"
        container = metric.get("container") or "unknown"
        # This report runs as a transient compose container with a fresh name
        # every time, so its own log lines would mint a brand-new observation
        # id per run and leave it in the seen-state forever.
        if is_ephemeral(container):
            continue
        per_container[(host, container)] = int(value)

    # Signatures need the actual lines, so this one stays a range query. The
    # sample is capped, which is fine: identity is what matters here, and the
    # authoritative counts come from the aggregation above.
    streams = query_range(config, logql, hours)
    signatures = {}
    for stream in streams:
        labels = stream.get("stream", {})
        container = labels.get("container") or "unknown"
        host = labels.get("host") or labels.get("instance") or "unknown"
        if is_ephemeral(container):
            continue
        for _ts, line in stream.get("values", []):
            sig = normalize(line)
            if not sig:
                continue
            key = "%s|%s" % (container, sig)
            entry = signatures.setdefault(key, {
                "container": container,
                "host": host,
                "signature": sig,
                "count": 0,
                "example": line.strip()[:400],
            })
            entry["count"] += 1

    # Distinct error signatures appear constantly in a busy homelab: the first
    # real run produced 38 new-signature warnings in one go, which is precisely
    # the volume that trains you to ignore the report. Only signatures that
    # recur meaningfully are worth waking up for; the rest stay in `data` for
    # forensics without becoming observations.
    ranked = sorted(signatures.values(), key=lambda e: -e["count"])
    notable = [e for e in ranked if e["count"] >= MIN_SIGNATURE_COUNT][:MAX_SIGNATURES]

    result.data = {
        "signature_count": len(signatures),
        "notable_count": len(notable),
        "signatures": ranked[:100],
        "per_container": [
            {"host": h, "container": c, "errors": n}
            for (h, c), n in per_container.most_common(50)
        ],
    }

    # Emitted for every signature; the diff decides which are actually new, and
    # the severity rules only escalate the new ones.
    for entry in notable:
        obs.append(Observation(
            id="log_signature.%s.%s" % (entry["container"], _sig_key(entry["signature"])),
            collector="logs",
            subject=entry["host"],
            kind="log_signature",
            value=entry["count"],
            unit="occurrences_in_sample",
            # Signatures are kept at full length in `data`; the message is what
            # lands in a push notification, so it stays readable.
            message="%s: %s (x%d in sample)"
                    % (entry["container"], entry["signature"][:140], entry["count"]),
            evidence={"example": entry["example"], "logql": logql},
        ))

    for (host, container), count in per_container.most_common(50):
        obs.append(Observation(
            id="log_error_rate.%s.%s" % (host, container),
            collector="logs",
            subject=host,
            kind="log_error_rate",
            value=count,
            unit="lines",
            message="%s/%s logged %s error lines in %dh" % (host, container, f"{count:,}", hours),
            evidence={"logql": logql},
        ))

    # Authentication failures. Alloy ships /var/log/secure as job="auth".
    auth_logql = ('sum by (host) (count_over_time({job="auth"} |= "Failed password" [%dh]))'
                  % hours)
    auth_counts = Counter()
    for metric, value in query_instant(config, auth_logql):
        auth_counts[metric.get("host", "unknown")] = int(value)
    result.data["auth_failures"] = dict(auth_counts)
    for host, count in auth_counts.items():
        obs.append(Observation(
            id="auth_failures.%s." % host,
            collector="logs",
            subject=host,
            kind="auth_failures",
            value=count,
            unit="attempts",
            message="%s saw %d failed SSH password attempts in %dh" % (host, count, hours),
            evidence={"logql": auth_logql},
        ))

    # Caddy 5xx: the user-visible failure mode for every proxied service.
    #
    # Bucketed hourly rather than summed over the window, because a single
    # 24h total cannot tell a planned maintenance window from an outage. The
    # Sunday appdata backup alone contributes ~8,750 5xx across three hours;
    # summed flat, that buries a real incident and trains you to ignore the
    # number. Hours inside a declared window are dropped, and what is reported
    # is how many hours were actually bad.
    caddy_logql = ('sum by (host) (count_over_time({job="caddy"} | json | status >= 500 [1h]))')
    windows = parse_windows(config.maintenance_windows)
    hour_threshold = config.caddy_5xx_hour_threshold
    per_host_buckets = {}
    for metric, series in query_matrix(config, caddy_logql, hours, step=3600):
        per_host_buckets.setdefault(metric.get("host", "mljr"), []).extend(series)

    result.data["caddy_5xx"] = {}
    for host, series in per_host_buckets.items():
        kept, suppressed = split_maintenance(series, windows)
        total = int(sum(v for _ts, v in kept))
        suppressed_total = int(sum(v for _ts, v in suppressed))
        bad_hours = [(ts, v) for ts, v in kept if v >= hour_threshold]
        peak_ts, peak = max(kept, key=lambda p: p[1], default=(0, 0.0))

        result.data["caddy_5xx"][host] = {
            "total": total,
            "suppressed": suppressed_total,
            "suppressed_hours": len(suppressed),
            "bad_hours": len(bad_hours),
            "peak": int(peak),
        }
        evidence = {
            "logql": caddy_logql,
            "hour_threshold": hour_threshold,
            "peak_hour": _hour_label(peak_ts),
            "peak": int(peak),
            "maintenance_windows": config.maintenance_windows,
            "suppressed_responses": suppressed_total,
            "suppressed_hours": len(suppressed),
        }

        obs.append(Observation(
            id="caddy_5xx.%s." % host,
            collector="logs",
            subject=host,
            kind="caddy_5xx",
            value=total,
            unit="responses",
            message="%s served %s 5xx responses in %dh (excluding %d maintenance hour(s))"
                    % (host, f"{total:,}", hours, len(suppressed)),
            evidence=evidence,
        ))

        # The shape signal. One restart burst is one bad hour; a service that
        # is actually broken stays bad for many.
        obs.append(Observation(
            id="caddy_5xx_hours.%s." % host,
            collector="logs",
            subject=host,
            kind="caddy_5xx_hours",
            value=len(bad_hours),
            unit="hours",
            threshold=hour_threshold,
            message="%s had %d hour(s) above %d 5xx in %dh (peak %s at %s)"
                    % (host, len(bad_hours), hour_threshold, hours,
                       f"{int(peak):,}", _hour_label(peak_ts)),
            evidence=evidence,
        ))

    return result


def _sig_key(signature: str) -> str:
    """Stable, filesystem- and id-safe key for a signature."""
    import hashlib
    return hashlib.sha1(signature.encode("utf-8")).hexdigest()[:12]
