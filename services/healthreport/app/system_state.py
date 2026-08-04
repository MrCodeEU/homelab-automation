"""The "everything else" view: what the estate looks like when nothing is wrong.

The report was built to answer "what broke", which means a quiet day produces a
nearly empty email and you learn nothing from it - not whether backups ran, not
how full the disks are, not that a token expires in three weeks. Every number
below is already collected for threshold checks; this module only reshapes it
for display and adds no new collection.
"""

from typing import Dict, List

# Mounts that exist on every box and never say anything useful. /boot/efi and
# /efi are the same partition seen twice, and both sit at a permanent ~11%.
BORING_MOUNTS = ("/boot/efi", "/efi", "/dev/shm", "/run", "/var/lib/docker/overlay2")

# Below this a filesystem is not worth a row of its own in a summary that is
# meant to be skimmed.
INTERESTING_USED_PERCENT = 50.0

# Fewer than this many days left on a credential is worth saying out loud, since
# nothing else in the estate will mention it until it breaks.
TOKEN_WARN_DAYS = 30


def _collector_data(facts: Dict, name: str) -> Dict:
    collector = (facts.get("collectors") or {}).get(name) or {}
    return collector.get("data") or {}


def _by_instance(rows, key):
    out = {}
    for row in rows or []:
        instance = row.get("instance")
        if instance is not None and key in row:
            out[instance] = row[key]
    return out


def _humanize_uptime(seconds) -> str:
    try:
        days = int(seconds) // 86400
    except (TypeError, ValueError):
        return "?"
    if days >= 1:
        return "%dd" % days
    return "%dh" % (int(seconds) // 3600)


def hosts(facts: Dict) -> List[Dict]:
    """Per-host vitals, worst filesystem first."""
    metrics = _collector_data(facts, "host_metrics")
    memory = _by_instance(metrics.get("memory"), "used_percent")
    load = _by_instance(metrics.get("load_per_core"), "load15_per_core")
    uptime = _by_instance(metrics.get("uptime_seconds"), "uptime")

    filesystems = {}
    for row in metrics.get("filesystems") or []:
        mount = row.get("mountpoint")
        if not mount or mount in BORING_MOUNTS:
            continue
        filesystems.setdefault(row.get("instance"), []).append({
            "mountpoint": mount,
            "used_percent": row.get("used_percent"),
        })

    out = []
    for name in sorted(set(list(memory) + list(load) + list(uptime) + list(filesystems))):
        mounts = sorted(
            filesystems.get(name, []),
            key=lambda m: -(m["used_percent"] or 0),
        )
        # Always show the fullest mount even on a healthy host, so the row is
        # never empty; beyond that only the ones actually filling up.
        notable = [m for m in mounts if (m["used_percent"] or 0) >= INTERESTING_USED_PERCENT]
        out.append({
            "name": name,
            "memory_percent": memory.get(name),
            "load_per_core": load.get(name),
            "uptime": _humanize_uptime(uptime.get(name)),
            "filesystems": (notable or mounts[:1])[:4],
        })
    return out


def counts(facts: Dict) -> List[Dict]:
    """One-line totals, the "is the shape of the estate still what I expect" row."""
    containers = _collector_data(facts, "containers")
    kuma = _collector_data(facts, "uptime_kuma")
    github = _collector_data(facts, "github")
    ha = _collector_data(facts, "homeassistant")

    out = []
    if containers.get("current_count") is not None:
        out.append({"label": "Containers", "value": containers["current_count"]})
    if kuma.get("monitor_count") is not None:
        out.append({"label": "Monitors", "value": kuma["monitor_count"]})
    if github.get("repo_count") is not None:
        out.append({"label": "Repos", "value": github["repo_count"]})
    if ha.get("entity_count") is not None:
        out.append({"label": "HA entities", "value": ha["entity_count"]})
    return out


def backup_targets(facts: Dict) -> List[Dict]:
    """Where backups land, and how much room is left there.

    Sourced from the per-host facts payload rather than a collector of its own,
    because only the NAS holds the rclone config and the backup share.
    """
    out = []
    hosts = (_collector_data(facts, "ssh_facts") or {}).get("payloads") or {}
    for host, payload in sorted(hosts.items()):
        section = ((payload or {}).get("sections") or {}).get("backup_targets") or {}
        for target in (section.get("data") or {}).get("targets") or []:
            entry = {
                "host": host,
                "name": target.get("name"),
                "kind": target.get("kind"),
                "used_percent": target.get("used_percent"),
            }
            free = target.get("free_bytes")
            total = target.get("total_bytes")
            entry["free_gib"] = round(free / (1024.0 ** 3)) if free else None
            entry["total_gib"] = round(total / (1024.0 ** 3)) if total else None
            if not target.get("quota_supported"):
                entry["note"] = "no quota API"
            elif target.get("error"):
                entry["note"] = "unreachable"
            out.append(entry)
    return out


def notes(facts: Dict) -> List[str]:
    """Short informational lines that have no home in the severity table."""
    out = []

    github = _collector_data(facts, "github")
    days = github.get("token_expires_in_days")
    if isinstance(days, (int, float)) and days <= TOKEN_WARN_DAYS:
        out.append("GitHub token expires in %d days" % int(days))

    ha = _collector_data(facts, "homeassistant")
    if ha.get("version"):
        out.append("Home Assistant %s" % ha["version"])
    for update in ha.get("updates_available") or []:
        out.append("Update available: %s %s → %s" % (
            update.get("name"), update.get("installed"), update.get("latest")))

    return out
