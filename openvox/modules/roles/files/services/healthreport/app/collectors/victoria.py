"""Host and container facts from VictoriaMetrics.

Grafana Alloy already ships node, cadvisor and CrowdSec metrics from mljr and
nuc (and nas once services/nas-alloy is deployed), so nearly everything here
is a PromQL query rather than a login to a box.
"""

import re

from ..model import CollectorResult, Observation, is_ephemeral
from .base import collector, http_get

# Session-scope units flap on every SSH/console login and carry no signal -
# on mljr these accounted for 14 of 15 "failed" units reported by the old
# SSH-based collector (see ssh_facts.py's history). PromQL has no built-in
# way to exclude these inside the query itself, so this is applied to the
# query results below instead, to avoid reintroducing noise the SSH path
# had already filtered out.
SYSTEMD_NOISE = re.compile(r"^session-c?\d+\.scope$")

# Pseudo-filesystems that are always ~100% full or always empty, and say
# nothing about the health of the machine.
FS_EXCLUDE = 'fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660|autofs"'

# Retired-but-kept mounts: not receiving new data, so predict_linear's 7-day
# window keeps extrapolating a one-time historical drop (the last write to
# it) as an ongoing trend forever. Real disk_usage still reports on these
# fine - only the fill-projection is meaningless for a mount nothing writes
# to anymore. /mnt/cache on nas is the old Intenso SSD, superseded by
# fastpool as the real cache and kept around unused rather than retired.
DISK_FILL_PROJECTION_EXCLUDE = {("nas", "/mnt/cache")}

# Ephemeral container matching lives in ..model so the log collectors apply the
# same rule; reporting these as "missing since yesterday" would be a daily false
# positive here, and a permanent new seen-state entry there.


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
        if (host, mount) in DISK_FILL_PROJECTION_EXCLUDE:
            continue
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
    # Live since the 2026-08-11/12 monitoring expansion - Alloy's systemd
    # collector is now enabled fleet-wide (docker.sock already granted a
    # comparable privilege level, so mounting /run/systemd/private too was a
    # reasonable trade - see roles/grafana-alloy/templates/config.alloy.j2).
    # This was the sole source of systemd_failed until then via
    # ssh_facts.py's `systemctl list-units --failed`; that SSH-based path was
    # removed once this query was confirmed live (same kind, same ids, no
    # LLM-facing change). Unraid/wd_mycloud never appear here - neither runs
    # systemd - which is expected, not a gap.
    promql = 'node_systemd_unit_state{state="failed"} == 1'
    for metric, _value in query(config, promql):
        host = metric.get("instance", "unknown")
        unit = metric.get("name", "unknown")
        if SYSTEMD_NOISE.match(unit):
            continue
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

    # --- SMART health/temperature ------------------------------------------
    # Sourced from smartctl-exporter (ugreen/nuc/nas only - not mljr, a
    # Contabo VPS with virtio-only block storage and no real SMART data
    # behind it; not wd_mycloud, which has no Docker and so no exporter can
    # run there at all - its disk usage is still covered above via
    # node_exporter's generic filesystem metrics, just not SMART specifics).
    # Replaces the equivalent ssh_facts.py `smartctl`-over-SSH path for the
    # three hosts this covers.
    promql = "smartctl_device_smart_status"
    for metric, value in query(config, promql):
        host = metric.get("host", metric.get("instance", "unknown"))
        device = metric.get("device", "unknown")
        obs.append(Observation(
            id="smart_health.%s.%s" % (host, device),
            collector="host_metrics",
            subject=host,
            kind="smart_health",
            value=bool(value),
            message="%s %s SMART self-assessment %s" % (host, device, "passed" if value else "FAILED"),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    promql = 'smartctl_device_temperature{temperature_type="current"}'
    for metric, value in query(config, promql):
        host = metric.get("host", metric.get("instance", "unknown"))
        device = metric.get("device", "unknown")
        obs.append(Observation(
            id="disk_temperature.%s.%s" % (host, device),
            collector="host_metrics",
            subject=host,
            kind="disk_temperature",
            value=int(value),
            unit="celsius",
            message="%s %s at %d C" % (host, device, int(value)),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- btrfs pool errors ---------------------------------------------------
    # Sourced from Alloy's btrfs collector (ugreen and nas). Net-new coverage
    # for nas - the SSH-based equivalent in ssh_facts.py only ever checked
    # ugreen (via a ugreen-specific facts section), so nas btrfs errors were
    # never checked by anything before this.
    promql = "node_btrfs_device_errors_total"
    pool_errors = {}
    for metric, value in query(config, promql):
        if value <= 0:
            continue
        host = metric.get("host", metric.get("instance", "unknown"))
        device = metric.get("device", "unknown")
        error_type = metric.get("type", "unknown")
        key = (host, device)
        entry = pool_errors.setdefault(key, {})
        entry[error_type] = entry.get(error_type, 0) + value
    for (host, device), errors in pool_errors.items():
        obs.append(Observation(
            id="btrfs_pool_errors.%s.%s" % (host, device),
            collector="host_metrics",
            subject=host,
            kind="btrfs_pool_errors",
            value=sum(errors.values()),
            unit="errors",
            message="%s: btrfs device %s has errors: %s"
                    % (host, device, ", ".join("%s=%d" % (k, v) for k, v in errors.items())),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    # --- CrowdSec (mljr only) -----------------------------------------------
    # Supplements, does not replace, ssh_facts.py's cscli-based bouncer
    # health check (bouncer registration/liveness has no clean Prometheus
    # metric equivalent). This is the live-decisions/alert-volume signal the
    # existing homelab-security.json dashboard already visualizes - surfaced
    # here too so the daily LLM narrative can reference it without an SSH
    # round-trip.
    #
    # No severity rule in rules.yml for either new kind below (yet) -
    # deliberately, not an oversight. cs_active_decisions includes CAPI's
    # community-blocklist decisions, a fundamentally different scale from
    # the existing SSH-based crowdsec_decisions (which fires warn at 500) -
    # confirmed live 2026-08-13 this sums to ~24,000 under completely normal
    # conditions. Inventing a crit/warn threshold without a few days of real
    # baseline data first would just be a guess that either never fires or
    # fires constantly. Both stay info-severity (still visible to the LLM
    # and dashboards) until an actual baseline justifies real thresholds.
    promql = "sum by(host) (cs_active_decisions)"
    for metric, value in query(config, promql):
        host = metric.get("host", metric.get("instance", "unknown"))
        obs.append(Observation(
            id="crowdsec_active_decisions.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="crowdsec_active_decisions",
            value=int(value),
            unit="decisions",
            message="%s: %d active CrowdSec ban decision(s)" % (host, int(value)),
            evidence=dict(promql=promql, **_grafana(config)),
        ))

    promql = "sum by(host) (increase(cs_alerts[24h]))"
    for metric, value in query(config, promql):
        if value <= 0:
            continue
        host = metric.get("host", metric.get("instance", "unknown"))
        obs.append(Observation(
            id="crowdsec_alerts_24h.%s." % host,
            collector="host_metrics",
            subject=host,
            kind="crowdsec_alerts_24h",
            value=int(value),
            unit="alerts",
            message="%s: %d CrowdSec alert(s) in the last 24h" % (host, int(value)),
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

    def inventory(promql):
        return {
            (m.get("instance"), m.get("name"))
            for m, _ in query(config, promql)
            if not is_ephemeral(m.get("name") or "")
        }

    current = inventory(now_q)
    previous = inventory(then_q)

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
