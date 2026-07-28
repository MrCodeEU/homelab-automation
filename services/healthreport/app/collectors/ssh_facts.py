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
        args = ["ssh"] + SSH_OPTIONS + ["-i", config.ssh_key_path, "root@%s" % address]
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
        obs.append(Observation(
            id="security_updates.%s." % host,
            collector="ssh_facts",
            subject=host,
            kind="security_updates",
            value=updates.get("count", 0),
            unit="advisories",
            message="%s has %d pending security advisories" % (host, updates.get("count", 0)),
            evidence={"advisories": (updates.get("advisories") or [])[:10]},
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

    smart = _section(sections, "unraid_smart")
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

    for note in _section(sections, "unraid_notifications") or []:
        obs.append(Observation(
            id="unraid_notification.%s.%s" % (host, note.get("file")),
            collector="ssh_facts",
            subject=host,
            kind="unraid_notification",
            value=note.get("importance", "normal"),
            message="%s notification: %s - %s"
                    % (host, note.get("subject", "?"), (note.get("description") or "")[:120]),
            evidence={"event": note.get("event"), "importance": note.get("importance")},
        ))
