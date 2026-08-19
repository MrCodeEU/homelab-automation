"""Badge/status reduction logic - the part that decides what color an entry
shows as. Phase 1 deliberately reduces to host-level granularity; these
tests pin that behavior so it isn't silently "improved" into something the
data doesn't actually support (see collect.py's host_status docstring)."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.collect import entry_badge, host_status, target_usage  # noqa: E402


def facts_payload(available=True, completed=True, critical=0, failed_services=None):
    return {
        "sections": {
            "backup": {
                "data": {
                    "available": available,
                    "completed": completed,
                    "critical_failures": critical,
                    "failed_services": failed_services or [],
                    "age_seconds": 3600,
                }
            }
        }
    }


def test_host_status_ok():
    status = host_status(facts_payload(), None)
    assert status["state"] == "ok"
    assert status["age_seconds"] == 3600


def test_host_status_degraded_on_critical_failure():
    status = host_status(facts_payload(critical=2), None)
    assert status["state"] == "degraded"


def test_host_status_unreachable():
    status = host_status(None, "ssh timed out")
    assert status["state"] == "unknown"
    assert status["reason"] == "ssh timed out"


def test_host_status_no_log_available():
    status = host_status({"sections": {"backup": {"data": {"available": False, "reason": "no backup logs"}}}}, None)
    assert status["state"] == "unknown"
    assert status["reason"] == "no backup logs"


def test_target_usage_skips_unsupported_quota():
    payload = {"sections": {"backup_targets": {"data": {"targets": [
        {"name": "pcloud", "kind": "remote", "quota_supported": True, "used_percent": 67.1, "free_bytes": 10 * 1024**3},
        {"name": "wd-cloud", "kind": "remote", "quota_supported": False, "used_percent": None},
    ]}}}}
    usage = target_usage(payload, None)
    assert "pcloud" in usage
    assert usage["pcloud"]["used_percent"] == 67.1
    assert "wd-cloud" not in usage


def test_target_usage_skips_local_paths():
    # collect_backup_targets also reports kind == "local" staging paths
    # (borg/appdata on nas) - real disk usage, but not a "destination" in
    # the sense this page's summary row means. Found live: without this
    # filter, /mnt/user/backup and /mnt/fastpool showed up as destination
    # cards next to pcloud.
    payload = {"sections": {"backup_targets": {"data": {"targets": [
        {"name": "/mnt/user/backup", "kind": "local", "quota_supported": True, "used_percent": 28.9, "free_bytes": 1},
        {"name": "pcloud", "kind": "remote", "quota_supported": True, "used_percent": 48.7, "free_bytes": 1},
    ]}}}}
    usage = target_usage(payload, None)
    assert "/mnt/user/backup" not in usage
    assert "pcloud" in usage


def test_target_usage_empty_on_error():
    assert target_usage(None, "unreachable") == {}


def test_entry_badge_matches_ugreen_and_wd_cloud_leg_format():
    # unraid-backup's ugreen/wd_cloud legs append "(leg)" to the bare name
    # (see backup.sh.j2's failed_paths+=("{{ pair.name }} (ugreen)")).
    entry = {"name": "fotos", "host": "nas", "dest": "pcloud:Fotos"}
    assert entry_badge(entry, {"nas": {"state": "ok", "failed_services": ["fotos (wd-cloud)"]}}) == "failed"
    assert entry_badge(entry, {"nas": {"state": "ok", "failed_services": ["fotos (ugreen)"]}}) == "failed"


def test_entry_badge_matches_pcloud_leg_dest_format():
    # The pcloud leg uses the raw dest string, not the entry name (see
    # backup.sh.j2's failed_paths+=("{{ pair.dest }}")) - name-substring
    # matching alone would miss this.
    entry = {"name": "fotos", "host": "nas", "dest": "pcloud:Fotos"}
    assert entry_badge(entry, {"nas": {"state": "ok", "failed_services": ["pcloud:Fotos"]}}) == "failed"


def test_entry_badge_matches_bare_service_name():
    # The rocky `backup` role's service failures are just the bare name.
    entry = {"name": "mailcow", "host": "mljr"}
    assert entry_badge(entry, {"mljr": {"state": "ok", "failed_services": ["mailcow"]}}) == "failed"


def test_entry_badge_no_match_stays_at_host_state():
    entry = {"name": "fotos", "host": "nas", "dest": "pcloud:Fotos"}
    statuses = {"nas": {"state": "ok", "failed_services": ["musik (wd-cloud)"]}}
    assert entry_badge(entry, statuses) == "ok"


def test_entry_badge_falls_back_to_host_state():
    entry = {"name": "sync", "host": "nas"}
    statuses = {"nas": {"state": "degraded", "failed_services": []}}
    assert entry_badge(entry, statuses) == "degraded"


def test_entry_badge_unknown_for_missing_host():
    entry = {"name": "sync", "host": "ghost-host"}
    assert entry_badge(entry, {}) == "unknown"
