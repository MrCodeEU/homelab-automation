"""Facts that are not reachable over the network.

CrowdSec's LAPI is loopback-bound on mljr, the nftables ruleset is root-only,
and Unraid array/SMART state is not a network resource at all. Each host runs
a read-only script behind an SSH key restricted to that exact command; see
ansible/roles/host-facts-endpoint.

The local host runs the script directly rather than dialling itself.
"""

import json
import os
import subprocess
import time

from ..model import CollectorResult, Observation
from .base import collector

SSH_OPTIONS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "IdentitiesOnly=yes",
]


def fetch(config, host, address):
    if host == config.local_host:
        args = [config.local_facts_bin]
    else:
        # The command is named explicitly rather than relying on the
        # authorized_keys forced command. Tailscale SSH (RunSSH=true on all
        # hosts) terminates port 22 on the tailnet interface and authorizes
        # from the tailnet ACL without ever reading authorized_keys, so the
        # forced command does not apply on this path and a bare `ssh` yields a
        # login shell that returns nothing.
        #
        # Naming it is correct in both worlds: where real sshd does handle the
        # connection, the forced command overrides whatever is requested here.
        args = (["ssh"] + SSH_OPTIONS
                + ["-i", config.ssh_key_path, "root@%s" % address, config.local_facts_bin])
    proc = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, shell=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "%s: exit %d: %s" % (host, proc.returncode, proc.stderr.decode("utf-8", "replace")[:300])
        )
    return json.loads(proc.stdout.decode("utf-8", "replace"))


@collector("ssh_facts")
def collect(config, rules):
    result = CollectorResult(name="ssh_facts")
    obs = result.observations
    payloads = {}
    errors = {}

    targets = dict(config.ssh_hosts)
    if config.local_host not in targets and os.path.exists(config.local_facts_bin):
        targets[config.local_host] = "local"

    if not targets:
        # No configured hosts and no local script means this collector cannot
        # contribute anything. Report that rather than an empty success, which
        # would look identical to "everything is fine".
        result.status = "unavailable"
        result.error = "no facts endpoints configured (HEALTHREPORT_SSH_HOSTS)"
        return result

    for host, address in sorted(targets.items()):
        try:
            payloads[host] = fetch(config, host, address)
        except Exception as exc:
            errors[host] = str(exc)[:300]
            # A host whose facts cannot be read is itself a finding, not a
            # silent gap in the report.
            obs.append(Observation(
                id="facts_unreachable.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="facts_unreachable",
                value=str(exc)[:200],
                message="could not read host facts from %s" % host,
                evidence={"error": str(exc)[:300]},
            ))

    for host, payload in payloads.items():
        sections = payload.get("sections", {})
        _rocky(obs, host, sections)
        _unraid(obs, host, sections)

        for name, section in sections.items():
            if section.get("status") != "ok":
                obs.append(Observation(
                    id="facts_section_failed.%s.%s" % (host, name),
                    collector="ssh_facts",
                    subject=host,
                    kind="facts_section_failed",
                    value=name,
                    message="%s: facts section %s failed: %s" % (host, name, section.get("error")),
                    evidence={"error": section.get("error")},
                ))

    result.status = "error" if errors and not payloads else result.status
    result.error = "; ".join("%s: %s" % kv for kv in errors.items()) or None
    result.data = {"hosts": sorted(payloads.keys()), "errors": errors, "payloads": payloads}
    return result


def _section(sections, name):
    entry = sections.get(name) or {}
    if entry.get("status") != "ok":
        return None
    return entry.get("data")


def _rocky(obs, host, sections):
    units = _section(sections, "systemd_failed")
    if units:
        for unit in units:
            name = unit.get("unit", "unknown")
            obs.append(Observation(
                id="systemd_failed.%s.%s" % (host, name),
                collector="ssh_facts",
                subject=host,
                kind="systemd_failed",
                value=name,
                message="%s: systemd unit %s is failed" % (host, name),
                evidence={"description": unit.get("description")},
            ))

    updates = _section(sections, "security_updates")
    if updates is not None:
        count = updates.get("count", 0)
        packages = updates.get("distinct_package_count")
        reboot_required = updates.get("reboot_required")

        # The advisory count alone is misleading: dnf lists every superseded
        # advisory until the new kernel is actually running, so a host that is
        # fully patched but unrebooted looks catastrophically behind. Lead with
        # how many distinct packages are affected, which is the honest number.
        detail = "%d advisories" % count
        if packages is not None:
            detail += " across %d package(s)" % packages
        if reboot_required:
            detail += ", already installed and pending reboot"

        obs.append(Observation(
            id="security_updates.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="security_updates",
            value=count,
            unit="advisories",
            message="%s: %s" % (host, detail),
            evidence={
                "advisories": (updates.get("advisories") or [])[:10],
                "distinct_packages": (updates.get("distinct_packages") or [])[:20],
                "reboot_required": reboot_required,
                "running_kernel": updates.get("running_kernel"),
            },
        ))

        # Emitted only when true, so the `present` rule can speak for itself.
        # This is the finding that actually needs an action: the packages are
        # on disk, nothing is running them.
        if reboot_required:
            obs.append(Observation(
                id="reboot_required.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="reboot_required",
                value=updates.get("running_kernel") or True,
                message="%s needs a reboot to activate installed updates (running %s)"
                        % (host, updates.get("running_kernel") or "unknown kernel"),
                evidence={
                    "running_kernel": updates.get("running_kernel"),
                    "advisories_pending_reboot": count,
                },
            ))

    crowdsec = _section(sections, "crowdsec")
    if crowdsec and crowdsec.get("available"):
        decisions = crowdsec.get("decisions") or []
        obs.append(Observation(
            id="crowdsec_decisions.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="crowdsec_decisions",
            value=len(decisions),
            unit="decisions",
            message="%s: CrowdSec is enforcing %d decisions" % (host, len(decisions)),
            evidence={"sample": [d.get("value") for d in decisions[:10]]},
        ))
        for bouncer in crowdsec.get("bouncers") or []:
            name = bouncer.get("name", "unknown")
            obs.append(Observation(
                id="crowdsec_bouncer.%s.%s" % (host, name),
                collector="ssh_facts",
                subject=host,
                kind="crowdsec_bouncer",
                # cscli reports the string "true"/"false" or a boolean.
                value=str(bouncer.get("revoked", False)).lower() != "true",
                message="%s: CrowdSec bouncer %s last seen %s"
                        % (host, name, bouncer.get("last_pull", "never")),
                evidence={"last_pull": bouncer.get("last_pull")},
            ))
    elif crowdsec is not None and not crowdsec.get("available"):
        # Only meaningful on the host that is supposed to run CrowdSec; the
        # severity rules decide whether absence matters.
        obs.append(Observation(
            id="crowdsec_absent.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="crowdsec_absent",
            value=crowdsec.get("reason"),
            message="%s: CrowdSec not available (%s)" % (host, crowdsec.get("reason")),
            evidence={},
        ))

    nft = _section(sections, "nftables")
    if nft and not nft.get("error"):
        obs.append(Observation(
            id="firewall_rules.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="firewall_rules",
            value=nft.get("rule_count", 0),
            unit="rules",
            message="%s firewall has %d rules across %s"
                    % (host, nft.get("rule_count", 0), ", ".join(nft.get("tables") or [])),
            evidence={"set_element_counts": nft.get("set_element_counts")},
        ))

    # Capacity of the backup destinations themselves. A successful backup into a
    # target with no room left is not a successful backup for very long, and
    # nothing else in the report was watching this.
    targets = _section(sections, "backup_targets") or {}
    for target in targets.get("targets") or []:
        if not target.get("quota_supported") or target.get("used_percent") is None:
            continue
        free_gib = (target.get("free_bytes") or 0) / (1024.0 ** 3)
        obs.append(Observation(
            id="backup_target_usage.%s.%s" % (host, target["name"]),
            collector="ssh_facts",
            subject=host,
            kind="backup_target_usage",
            value=target["used_percent"],
            unit="percent",
            message="backup target %s is %.1f%% full (%.0f GiB free)"
                    % (target["name"], target["used_percent"], free_gib),
            evidence={
                "kind": target.get("kind"),
                "total_bytes": target.get("total_bytes"),
                "free_bytes": target.get("free_bytes"),
            },
        ))

    # Kernel-level trouble. Disks and filesystems complain here long before a
    # service notices - this is the signal that was missing when ugreen's cache
    # NVMe began failing and took the filesystem with it.
    kernel = _section(sections, "kernel_errors") or {}
    if kernel.get("available") and kernel.get("serious_count"):
        obs.append(Observation(
            id="kernel_storage_errors.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="kernel_storage_errors",
            value=kernel["serious_count"],
            unit="messages",
            message="%s: %d kernel message(s) indicating disk, filesystem or memory trouble"
                    % (host, kernel["serious_count"]),
            evidence={"sample": kernel.get("serious_sample", [])[:5]},
        ))

    # Clock drift breaks log correlation and TOTP before anything else notices.
    clock = _section(sections, "time_sync") or {}
    if clock.get("available"):
        if not clock.get("synchronised", True):
            obs.append(Observation(
                id="time_unsynchronised.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="time_unsynchronised",
                value=clock.get("source", "unknown"),
                message="%s: clock is not synchronised (%s)"
                        % (host, clock.get("reason") or clock.get("source")),
                evidence={"source": clock.get("source")},
            ))
        elif clock.get("offset_seconds") is not None:
            obs.append(Observation(
                id="time_offset.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="time_offset",
                value=round(clock["offset_seconds"], 3),
                unit="seconds",
                message="%s clock offset %.3fs (%s, stratum %s)"
                        % (host, clock["offset_seconds"], clock.get("source"),
                           clock.get("stratum")),
                evidence={"source": clock.get("source")},
            ))

    backup = _section(sections, "backup")
    if backup and backup.get("available"):
        age_h = (backup.get("age_seconds") or 0) / 3600.0
        obs.append(Observation(
            id="backup_age.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="backup_age",
            value=round(age_h, 1),
            unit="hours",
            message="%s last backup ran %.1f hours ago" % (host, age_h),
            evidence={"file": backup.get("file")},
        ))
        if backup.get("completed"):
            obs.append(Observation(
                id="backup_failures.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="backup_failures",
                value=backup.get("critical_failures", 0),
                unit="critical_failures",
                message="%s backup: %d critical, %d non-critical failures%s"
                        % (host,
                           backup.get("critical_failures", 0),
                           backup.get("non_critical_failures", 0),
                           (" (%s)" % ", ".join(backup["failed_services"]))
                           if backup.get("failed_services") else ""),
                evidence={"failed_services": backup.get("failed_services")},
            ))
            for service in backup.get("failed_services") or []:
                obs.append(Observation(
                    id="backup_service_failed.%s.%s" % (host, service),
                    collector="ssh_facts",
                    subject=host,
                    kind="backup_service_failed",
                    value=service,
                    message="%s: backup of %s failed" % (host, service),
                    evidence={},
                ))
        else:
            obs.append(Observation(
                id="backup_incomplete.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="backup_incomplete",
                value=True,
                message="%s: last backup log has no summary - the run did not finish" % host,
                evidence={"file": backup.get("file")},
            ))
    elif backup is not None:
        obs.append(Observation(
            id="backup_missing.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="backup_missing",
            value=backup.get("reason"),
            message="%s: no backup log found (%s)" % (host, backup.get("reason")),
            evidence={},
        ))


def _unraid(obs, host, sections):
    array = _section(sections, "unraid_array")
    if array:
        obs.append(Observation(
            id="array_state.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="array_state",
            value=array.get("state"),
            message="%s array is %s" % (host, array.get("state")),
            evidence={"disks": len(array.get("disks") or [])},
        ))
        obs.append(Observation(
            id="parity_sync_errors.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="parity_sync_errors",
            value=array.get("sync_errors") or 0,
            unit="errors",
            message="%s parity reports %s sync errors" % (host, array.get("sync_errors")),
            evidence={},
        ))
        age = array.get("last_check_age_seconds")
        if age:
            obs.append(Observation(
                id="parity_check_age.%s." % host,
                collector="ssh_facts",
                subject=host,
                kind="parity_check_age",
                value=round(age / 86400.0, 1),
                unit="days",
                message="%s last parity check finished %.1f days ago" % (host, age / 86400.0),
                evidence={"exit_code": array.get("sync_exit_code")},
            ))
        for disk in array.get("disks") or []:
            status = disk.get("status")
            obs.append(Observation(
                id="array_disk.%s.%s" % (host, disk.get("name") or disk.get("slot")),
                collector="ssh_facts",
                subject=host,
                kind="array_disk",
                value=status,
                message="%s disk %s is %s" % (host, disk.get("name"), status),
                evidence={"id": disk.get("id")},
            ))

    # "smart" is emitted by every host that has smartctl; "unraid_smart" is the
    # older Unraid-only key, kept as a fallback so a facts endpoint that has not
    # been redeployed yet still reports disks.
    smart = _section(sections, "smart") or _section(sections, "unraid_smart")
    if smart:
        for device in smart.get("devices") or []:
            name = device.get("device", "unknown")
            if device.get("error"):
                continue
            obs.append(Observation(
                id="smart_health.%s.%s" % (host, name),
                collector="ssh_facts",
                subject=host,
                kind="smart_health",
                value=bool(device.get("passed")),
                message="%s %s SMART self-assessment %s"
                        % (host, name, "passed" if device.get("passed") else "FAILED"),
                evidence={"model": device.get("model")},
            ))
            temp = device.get("temperature_c")
            if temp is not None:
                obs.append(Observation(
                    id="disk_temperature.%s.%s" % (host, name),
                    collector="ssh_facts",
                    subject=host,
                    kind="disk_temperature",
                    value=temp,
                    unit="celsius",
                    message="%s %s at %d C" % (host, name, temp),
                    evidence={"model": device.get("model")},
                ))
            # These two only matter as a trend, which the seen-state provides.
            for field, kind in (("reallocated_sectors", "reallocated_sectors"),
                                ("pending_sectors", "pending_sectors")):
                value = device.get(field)
                if value is None:
                    continue
                obs.append(Observation(
                    id="%s.%s.%s" % (kind, host, name),
                    collector="ssh_facts",
                    subject=host,
                    kind=kind,
                    value=value,
                    unit="sectors",
                    message="%s %s %s: %s" % (host, name, kind.replace("_", " "), value),
                    evidence={"model": device.get("model")},
                ))

    docker_image = _section(sections, "unraid_docker_image")
    if docker_image and docker_image.get("used_percent") is not None:
        obs.append(Observation(
            id="docker_image_usage.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="docker_image_usage",
            value=docker_image["used_percent"],
            unit="percent",
            message="%s docker.img is %.1f%% full" % (host, docker_image["used_percent"]),
            evidence={"path": docker_image.get("image_path")},
        ))

    # Unraid keeps every unread notification as its own file, so a recurring
    # problem produces one per occurrence - AppdataBackup alone accounted for
    # 13 identical observations on the first run. Collapse by event and
    # severity so a repeating issue is one finding with a count.
    grouped = {}
    for note in _section(sections, "unraid_notifications") or []:
        event = note.get("event") or "notification"
        importance = note.get("importance", "normal")
        entry = grouped.setdefault((event, importance), {
            "count": 0, "subject": note.get("subject", "?"),
            "description": note.get("description") or "",
        })
        entry["count"] += 1

    for (event, importance), entry in sorted(grouped.items()):
        suffix = "" if entry["count"] == 1 else " (x%d unread)" % entry["count"]
        obs.append(Observation(
            # Importance is part of the identity: grouping only by event made
            # an "alert" and a "warning" for the same event collide on one id,
            # so the more severe one could be silently overwritten.
            id="unraid_notification.%s.%s/%s" % (host, event, importance),
            collector="ssh_facts",
            subject=host,
            kind="unraid_notification",
            value=importance,
            unit=None,
            message="%s notification: %s - %s%s"
                    % (host, entry["subject"], entry["description"][:120], suffix),
            evidence={"event": event, "importance": importance, "unread": entry["count"]},
        ))
