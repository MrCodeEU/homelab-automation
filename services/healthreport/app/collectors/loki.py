"""Log-derived facts from Loki.

The valuable signal is not the error *rate* - that is noisy and mostly
constant. It is the appearance of an error *signature* that has never been
seen before. Signatures are normalized (numbers, hashes, IPs, UUIDs masked) so
that a thousand variations of the same message collapse into one identity.
"""

import re
import time
from collections import Counter

from ..model import CollectorResult, Observation
from .base import collector, http_get

ERROR_PATTERN = "(?i)(error|fatal|panic|traceback|exception)"

# Structured logs carry an error field on success too: Caddy access logs all
# contain `error=<nil>`, which made every served request look like an error and
# inflated the daily count into the tens of thousands. Drop the "no error"
# idioms before counting.
NOT_ERROR_PATTERN = r'(error=<nil>|error=null|"error":null|"error":""|err=<nil>|error=\s*$)'

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
            message="%s/%s logged %d error lines in %dh" % (host, container, count, hours),
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
    caddy_logql = ('sum by (host) (count_over_time({job="caddy"} | json | status >= 500 [%dh]))'
                   % hours)
    caddy_counts = Counter()
    for metric, value in query_instant(config, caddy_logql):
        caddy_counts[metric.get("host", "mljr")] = int(value)
    result.data["caddy_5xx"] = dict(caddy_counts)
    for host, count in caddy_counts.items():
        obs.append(Observation(
            id="caddy_5xx.%s." % host,
            collector="logs",
            subject=host,
            kind="caddy_5xx",
            value=count,
            unit="responses",
            message="%s served %d 5xx responses in %dh" % (host, count, hours),
            evidence={"logql": caddy_logql},
        ))

    return result


def _sig_key(signature: str) -> str:
    """Stable, filesystem- and id-safe key for a signature."""
    import hashlib
    return hashlib.sha1(signature.encode("utf-8")).hexdigest()[:12]
