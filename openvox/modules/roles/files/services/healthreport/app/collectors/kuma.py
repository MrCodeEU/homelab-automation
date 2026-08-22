"""Uptime Kuma monitor state.

Kuma exposes a Prometheus endpoint at /metrics behind HTTP basic auth: empty
username, API key as the password. Parsed directly rather than scraped into
VictoriaMetrics so a Kuma outage is visible as a collector failure instead of
silently stale data.
"""

import re

from ..model import CollectorResult, Observation
from .base import collector, http_get

# monitor_status{monitor_name="x",...} 1
SAMPLE = re.compile(r'^(?P<name>[a-z_]+)\{(?P<labels>[^}]*)\}\s+(?P<value>[-\d.eE+]+)\s*$')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')

# Kuma status codes: 0 down, 1 up, 2 pending, 3 maintenance.
STATUS_NAMES = {0: "down", 1: "up", 2: "pending", 3: "maintenance"}


def parse_metrics(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = SAMPLE.match(line)
        if not match:
            continue
        labels = {k: v.replace('\\"', '"') for k, v in LABEL.findall(match.group("labels"))}
        try:
            value = float(match.group("value"))
        except ValueError:
            continue
        out.append((match.group("name"), labels, value))
    return out


@collector("uptime_kuma")
def collect(config, rules):
    result = CollectorResult(name="uptime_kuma")
    obs = result.observations

    if not config.kuma_api_key:
        result.status = "unavailable"
        result.error = "no Kuma API key configured (secrets.kuma.api_key)"
        return result

    response = http_get(
        config.kuma_url.rstrip("/") + "/metrics",
        auth=("", config.kuma_api_key),
        timeout=30,
    )
    samples = parse_metrics(response.text)

    monitors = {}
    for name, labels, value in samples:
        key = labels.get("monitor_name") or labels.get("monitor_url") or "unknown"
        entry = monitors.setdefault(key, {"name": key, "url": labels.get("monitor_url")})
        if name == "monitor_status":
            entry["status"] = int(value)
        elif name == "monitor_cert_days_remaining":
            entry["cert_days"] = int(value)
        elif name == "monitor_response_time":
            entry["response_ms"] = value

    result.data = {"monitor_count": len(monitors), "monitors": list(monitors.values())}

    for entry in monitors.values():
        name = entry["name"]
        status = entry.get("status")
        if status is not None:
            obs.append(Observation(
                id="monitor_status.%s." % name,
                collector="uptime_kuma",
                subject=name,
                kind="monitor_status",
                value=STATUS_NAMES.get(status, str(status)),
                message="monitor %s is %s" % (name, STATUS_NAMES.get(status, status)),
                evidence={"kuma_url": config.kuma_url, "monitor_url": entry.get("url")},
            ))
        # Kuma reports -1 when it has no certificate information (plain HTTP,
        # TCP monitors). Only real certificates carry signal.
        cert_days = entry.get("cert_days")
        if cert_days is not None and cert_days >= 0:
            obs.append(Observation(
                id="cert_expiry.%s." % name,
                collector="uptime_kuma",
                subject=name,
                kind="cert_expiry",
                value=cert_days,
                unit="days",
                message="certificate for %s expires in %d days" % (name, cert_days),
                evidence={"monitor_url": entry.get("url")},
            ))

    return result
