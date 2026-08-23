"""Entry point: gather state, render the static page.

    python -m app.collect

One-shot, invoked by a systemd timer via `docker compose run` - see
hooks/post-deploy.sh, mirroring services/healthreport's pattern.
"""

import datetime
import json
import logging
import os
import sys

import jinja2

from . import facts, victoria
from .config import Config

LOG = logging.getLogger("backup-dashboard")


def load_catalog(path):
    with open(path, "r") as fh:
        return json.load(fh)


def host_status(payload, error):
    """Reduce one host's facts payload to what the page needs.

    Phase 1 limitation, surfaced on the page rather than hidden: this is the
    host's last backup run as a whole, not per-entry. An entry named in
    failed_services is shown as failed regardless; everything else on that
    host reads as the host's own aggregate outcome, which can't yet
    distinguish "this entry succeeded on an otherwise-failing host" from
    "this entry is one of the ones that failed silently" - see the plan's
    Phase 2 for the per-entry log parser that closes this gap.
    """
    if error:
        return {"state": "unknown", "reason": error, "failed_services": [],
                "age_seconds": None}
    backup = (payload or {}).get("sections", {}).get("backup", {}).get("data") or {}
    if not backup.get("available"):
        return {"state": "unknown", "reason": backup.get("reason", "no data"),
                "failed_services": [], "age_seconds": None}
    critical = backup.get("critical_failures") or 0
    state = "ok" if backup.get("completed") and critical == 0 else "degraded"
    return {
        "state": state,
        "reason": None,
        "failed_services": backup.get("failed_services") or [],
        "age_seconds": backup.get("age_seconds"),
    }


def target_usage(payload, error):
    """{target_name: {used_percent, free_gib}} for this host's facts payload.

    Only kind == "remote" (pcloud/ugreen/wd-cloud) - collect_backup_targets
    also reports kind == "local" entries (borg/appdata staging paths on
    nas), which are real disk usage but not "destinations" in the sense
    this page's summary row means. Confirmed live: without this filter,
    nas's local staging paths showed up as destination cards next to
    pcloud, which reads as more remotes existing than actually do.
    """
    if error:
        return {}
    targets = (payload or {}).get("sections", {}).get("backup_targets", {}).get("data") or {}
    out = {}
    for t in targets.get("targets") or []:
        if t.get("kind") != "remote":
            continue
        if not t.get("quota_supported") or t.get("used_percent") is None:
            continue
        out[t["name"]] = {
            "used_percent": round(t["used_percent"], 1),
            "free_gib": round((t.get("free_bytes") or 0) / (1024.0 ** 3), 1),
        }
    return out


def entry_badge(entry, statuses):
    """Is this specific entry named in its host's failure list?

    The three backup scripts format a failure differently (see
    ansible/roles/unraid-backup/templates/backup.sh.j2 and ansible/roles/
    backup/templates/backup.sh.j2): the pcloud leg uses the raw dest string
    ("pcloud:Fotos"), the ugreen/wd_cloud legs append "(leg)" to the entry
    name, and the rocky `backup` role's service failures are the bare
    service name. A substring check on the name covers the two name-based
    formats; an exact check against `dest` covers the pcloud one.
    """
    host_state = statuses.get(entry["host"], {})
    failed = host_state.get("failed_services") or []
    dest = entry.get("dest")
    for item in failed:
        if item == dest or entry["name"] in item:
            return "failed"
    return host_state.get("state", "unknown")


def build_snapshot(config):
    catalog = load_catalog(config.catalog_path)
    payloads, errors = facts.fetch_all(config)

    statuses = {
        host: host_status(payloads.get(host), errors.get(host))
        for host in config.ssh_hosts
    }
    # Destination usage is only meaningful from whichever host actually has
    # rclone configured against it - any host that returns targets works, the
    # remotes are the same wherever they are configured.
    destinations = {}
    for host in config.ssh_hosts:
        destinations.update(target_usage(payloads.get(host), errors.get(host)))

    source_disk = victoria.disk_usage(config.victoria_url)

    entries = []
    for entry in catalog.get("entries", []):
        entries.append({
            **entry,
            "badge": entry_badge(entry, statuses),
        })

    return {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "catalog_generated_at": catalog.get("generated_at"),
        "hosts": statuses,
        "destinations": destinations,
        "source_disk": source_disk,
        "entries": entries,
        "errors": errors,
    }


def render(config, snapshot):
    loader = jinja2.FileSystemLoader(os.path.dirname(config.template_path))
    env = jinja2.Environment(loader=loader, autoescape=True)
    template = env.get_template(os.path.basename(config.template_path))
    return template.render(**snapshot)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s backup-dashboard: %(message)s")
    config = Config.from_env()

    snapshot = build_snapshot(config)

    os.makedirs(config.state_dir, exist_ok=True)
    with open(os.path.join(config.state_dir, "snapshot.json"), "w") as fh:
        json.dump(snapshot, fh, indent=2, default=str)

    html = render(config, snapshot)
    os.makedirs(os.path.dirname(config.output_path), exist_ok=True)
    with open(config.output_path, "w") as fh:
        fh.write(html)

    LOG.info(
        "done: %d entries, %d/%d hosts reachable",
        len(snapshot["entries"]),
        sum(1 for s in snapshot["hosts"].values() if s["state"] != "unknown"),
        len(snapshot["hosts"]),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
