"""Source-host disk usage from VictoriaMetrics.

Same query shape as services/healthreport/app/collectors/victoria.py's
filesystem check - kept minimal here since capacity gauges are the only
thing this page needs from VictoriaMetrics for Phase 1.
"""

import logging

import requests

LOG = logging.getLogger("backup-dashboard")

FS_EXCLUDE = 'fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660|autofs"'


def query(victoria_url, promql):
    response = requests.get(
        victoria_url.rstrip("/") + "/api/v1/query",
        params={"query": promql},
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    if payload.get("status") != "success":
        raise RuntimeError("query failed: %s" % payload.get("error", "unknown"))
    out = []
    for series in payload.get("data", {}).get("result", []):
        try:
            out.append((series.get("metric", {}), float(series["value"][1])))
        except (KeyError, IndexError, ValueError):
            continue
    return out


def disk_usage(victoria_url):
    """Return {instance: {mountpoint: used_percent}}, or {} on failure."""
    promql = (
        "100 - (node_filesystem_avail_bytes{%s} / node_filesystem_size_bytes{%s} * 100)"
        % (FS_EXCLUDE, FS_EXCLUDE)
    )
    try:
        rows = query(victoria_url, promql)
    except Exception as exc:  # noqa: BLE001 - reported, not fatal
        LOG.warning("victoria disk_usage query failed: %s", exc)
        return {}
    out = {}
    for metric, value in rows:
        instance = metric.get("instance", "")
        mount = metric.get("mountpoint", "")
        out.setdefault(instance, {})[mount] = round(value, 1)
    return out
