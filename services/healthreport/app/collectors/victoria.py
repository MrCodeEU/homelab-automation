"""Host and container facts from VictoriaMetrics.

Grafana Alloy already ships node, cadvisor and CrowdSec metrics from mljr and
nuc (and nas once services/nas-alloy is deployed), so nearly everything here
is a PromQL query rather than a login to a box.
"""

from ..model import CollectorResult, Observation
from .base import collector, http_get

# Pseudo-filesystems that are always ~100% full or always empty, and say
# nothing about the health of the machine.
FS_EXCLUDE = 'fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660|autofs"'


def query(config, promql):
    """Run an instant query. Returns a list of (labels, float value)."""
    response = http_get(
        config.victoria_url.rstrip("/") + "/api/v1/query",
        params={"query": promql},
        timeout=30,
    )
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


def _grafana(config):
    return {"grafana_url": config.grafana_url}


@collector("host_metrics")
def collect(config, rules):
    result = CollectorResult(name="host_metrics")
    obs = result.observations
    data = {}

    # --- filesystems -------------------------------------------------------
    promql = (
        "100 - (node_filesystem_avail_bytes{%s} / node_filesystem_size_bytes{%s} * 100)"
        % (FS_EXCLUDE, FS_EXCLUDE)
    )
    rows = query(config, promql)
    data["filesystems"] = [
        {"instance": m.get("instance"), "mountpoint": m.get("mountpoint"), "used_percent": round(v, 2)}
        for m, v in rows
    ]
    for metric, value in rows:
        host = metric.get("instance", "unknown")
        mount = metric.get("mountpoint", "?")
        obs.append(Observation(
            id="disk_usage.%s.%s" % (host, mount),
            collector="host_metrics",
            subject=host,
            kind="disk_usage",
            value=round(value, 2),
            unit="percent",
            message="%s %s at %.1f%% used" % (host, mount, value),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- projected exhaustion ---------------------------------------------
    # predict_linear over a week, extrapolated a fortnight ahead. Negative
    # means the filesystem is on track to be full before then.
    promql = (
        "predict_linear(node_filesystem_avail_bytes{%s}[7d], 14 * 86400)" % FS_EXCLUDE
    )
    for metric, value in query(config, promql):
        if value >= 0:
            continue
        host = metric.get("instance", "unknown")
        mount = metric.get("mountpoint", "?")
        obs.append(Observation(
            id="disk_fill_projection.%s.%s" % (host, mount),
            collector="host_metrics",
            subject=host,
            kind="disk_fill_projection",
            value=round(value / (1024.0 ** 3), 2),
            unit="gib_projected_free",
            message="%s %s is projected to run out of space within 14 days" % (host, mount),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- memory ------------------------------------------------------------
    promql = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
    rows = query(config, promql)
    data["memory"] = [{"instance": m.get("instance"), "used_percent": round(v, 2)} for m, v in rows]
    for metric, value in rows:
        host = metric.get("instance", "unknown")
        obs.append(Observation(
            id="memory_usage.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="memory_usage",
            value=round(value, 2),
            unit="percent",
            message="%s memory at %.1f%% used" % (host, value),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- load per core -----------------------------------------------------
    promql = (
        "node_load15 / on(instance) group_left "
        'count by(instance) (node_cpu_seconds_total{mode="idle"})'
    )
    rows = query(config, promql)
    data["load_per_core"] = [{"instance": m.get("instance"), "load15_per_core": round(v, 2)} for m, v in rows]
    for metric, value in rows:
        host = metric.get("instance", "unknown")
        obs.append(Observation(
            id="load_per_core.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="load_per_core",
            value=round(value, 2),
            unit="ratio",
            message="%s 15m load is %.2f per core" % (host, value),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- CPU steal (VPS noisy-neighbour detection) -------------------------
    promql = '100 * avg by(instance) (rate(node_cpu_seconds_total{mode="steal"}[1h]))'
    for metric, value in query(config, promql):
        host = metric.get("instance", "unknown")
        obs.append(Observation(
            id="cpu_steal.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="cpu_steal",
            value=round(value, 2),
            unit="percent",
            message="%s CPU steal at %.1f%% over the last hour" % (host, value),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- unexpected reboot -------------------------------------------------
    promql = "time() - node_boot_time_seconds"
    rows = query(config, promql)
    data["uptime_seconds"] = [{"instance": m.get("instance"), "uptime": int(v)} for m, v in rows]
    for metric, value in rows:
        host = metric.get("instance", "unknown")
        obs.append(Observation(
            id="recent_reboot.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="recent_reboot",
            value=int(value),
            unit="seconds_since_boot",
            message="%s booted %.1f hours ago" % (host, value / 3600.0),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- failed systemd units ---------------------------------------------
    # Requires enable_collectors = ["systemd"] in the Alloy config.
    promql = 'node_systemd_unit_state{state="failed"} == 1'
    for metric, _value in query(config, promql):
        host = metric.get("instance", "unknown")
        unit = metric.get("name", "unknown")
        obs.append(Observation(
            id="systemd_failed.%s.%s" % (host, unit),
            collector="host_metrics",
            subject=host,
            kind="systemd_failed",
            value=unit,
            message="%s: systemd unit %s is failed" % (host, unit),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- metric staleness --------------------------------------------------
    # A host that stopped reporting is invisible to every query above, so it
    # must be checked explicitly against the expected host list.
    promql = "time() - max by(instance) (timestamp(node_load1))"
    seen = {}
    for metric, value in query(config, promql):
        seen[metric.get("instance", "unknown")] = value
    data["metrics_age_seconds"] = {k: round(v, 1) for k, v in seen.items()}
    for host in config.all_hosts():
        age = seen.get(host)
        if age is None:
            obs.append(Observation(
                id="metrics_missing.%s." % host,
                collector="host_metrics",
                subject=host,
                kind="metrics_missing",
                value=None,
                message="%s is not reporting any metrics" % host,
                evidence=dict(promql=promql, **_grafana(config)),
            ))
        else:
            obs.append(Observation(
                id="metrics_stale.%s." % host,
                collector="host_metrics",
                subject=host,
                kind="metrics_stale",
                value=round(age, 1),
                unit="seconds",
                message="%s metrics are %.0f seconds old" % (host, age),
                evidence=dict(promql=promql, **_grafana(config)),
            ))

    result.data = data
    return result


@collector("containers")
def collect_containers(config, rules):
    """Container inventory drift and restart loops.

    The important query is the inventory diff: a container that existed 24h ago
    and does not exist now is exactly the silent failure this report is for.
    """
    result = CollectorResult(name="containers")
    obs = result.observations
    lookback = "%dh" % config.lookback_hours

    now_q = 'count by(instance, name) (container_last_seen{name!=""})'
    then_q = 'count by(instance, name) (container_last_seen{name!=""} offset %s)' % lookback

    current = {(m.get("instance"), m.get("name")) for m, _ in query(config, now_q)}
    previous = {(m.get("instance"), m.get("name")) for m, _ in query(config, then_q)}

    # Only compare hosts present on both sides of the window. This suppresses
    # two false-positive floods: a host that was down for the whole lookback,
    # and the one-off churn after an `instance` label is rewritten (as happened
    # when mljr stopped reporting as vmi2945702.contaboserver.net).
    comparable = {h for h, _ in current} & {h for h, _ in previous}
    current = {(h, n) for h, n in current if h in comparable}
    previous = {(h, n) for h, n in previous if h in comparable}

    for host, name in sorted(previous - current):
        obs.append(Observation(
            id="container_missing.%s.%s" % (host, name),
            collector="containers",
            subject=host or "unknown",
            kind="container_missing",
            value=name,
            message="%s: container %s was running %s ago and is gone now" % (host, name, lookback),
            evidence={"promql": then_q, "grafana_url": config.grafana_url},
        ))

    for host, name in sorted(current - previous):
        obs.append(Observation(
            id="container_new.%s.%s" % (host, name),
            collector="containers",
            subject=host or "unknown",
            kind="container_new",
            value=name,
            message="%s: container %s appeared in the last %s" % (host, name, lookback),
            evidence={"promql": now_q},
        ))

    restart_q = 'changes(container_start_time_seconds{name!=""}[%s])' % lookback
    for metric, value in query(config, restart_q):
        if value <= 1:
            continue
        host = metric.get("instance", "unknown")
        name = metric.get("name", "unknown")
        obs.append(Observation(
            id="container_restarts.%s.%s" % (host, name),
            collector="containers",
            subject=host,
            kind="container_restarts",
            value=int(value),
            unit="restarts",
            message="%s: container %s restarted %d times in %s" % (host, name, value, lookback),
            evidence={"promql": restart_q, "grafana_url": config.grafana_url},
        ))

    oom_q = "increase(container_oom_events_total[%s])" % lookback
    for metric, value in query(config, oom_q):
        if value < 1:
            continue
        host = metric.get("instance", "unknown")
        name = metric.get("name", "unknown")
        obs.append(Observation(
            id="container_oom.%s.%s" % (host, name),
            collector="containers",
            subject=host,
            kind="container_oom",
            value=int(value),
            unit="events",
            message="%s: container %s was OOM-killed %d times in %s" % (host, name, value, lookback),
            evidence={"promql": oom_q, "grafana_url": config.grafana_url},
        ))

    result.data = {
        "current_count": len(current),
        "previous_count": len(previous),
        "missing": sorted("%s/%s" % (h, n) for h, n in previous - current),
        "new": sorted("%s/%s" % (h, n) for h, n in current - previous),
    }
    return result
