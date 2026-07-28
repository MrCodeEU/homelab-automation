"""Severity rules are the part that decides what the report says. If these
break, the LLM cannot save the report - it is explicitly forbidden from
re-judging severity."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.model import Observation          # noqa: E402
from app.severity import classify, apply, load_rules   # noqa: E402

RULES = load_rules(os.path.join(os.path.dirname(__file__), "..", "rules.yml"))
TABLE = RULES["rules"]


def obs(kind, value, subject="mljr", obs_id=None):
    return Observation(
        id=obs_id or "%s.%s." % (kind, subject),
        collector="test", subject=subject, kind=kind, value=value, message="x",
    )


def check(kind, value, expected, **kwargs):
    got = classify(obs(kind, value, **kwargs), TABLE.get(kind, {}))
    assert got == expected, "%s=%r expected %s, got %s" % (kind, value, expected, got)


def test_thresholds_above():
    check("disk_usage", 50, "info")
    check("disk_usage", 86, "warn")
    check("disk_usage", 91, "crit")
    # Boundary: the rule is strictly greater-than.
    check("disk_usage", 85, "info")
    check("disk_usage", 90, "warn")


def test_thresholds_below():
    check("cert_expiry", 60, "info")
    check("cert_expiry", 20, "warn")
    check("cert_expiry", 3, "crit")


def test_equals_and_not_equals():
    check("monitor_status", "up", "info")
    check("monitor_status", "down", "crit")
    check("monitor_status", "pending", "warn")
    check("array_state", "STARTED", "info")
    check("array_state", "STOPPED", "crit")


def test_falsy_escalates():
    check("smart_health", True, "info")
    check("smart_health", False, "crit")
    # A string "false" must not read as truthy.
    check("smart_health", "false", "crit")


def test_zero_tolerance_counters():
    check("parity_sync_errors", 0, "info")
    check("parity_sync_errors", 1, "crit")
    check("pending_sectors", 0, "info")
    check("pending_sectors", 4, "crit")


def test_subject_scoping():
    # crowdsec_absent only matters on mljr.
    check("crowdsec_absent", "not running", "crit", subject="mljr")
    check("crowdsec_absent", "not running", "info", subject="nuc")


def test_new_only_needs_the_diff():
    rule = TABLE["log_signature"]
    signature = obs("log_signature", 5)
    assert classify(signature, rule, is_new=False) == "info"
    assert classify(signature, rule, is_new=True) == "warn"


def test_unknown_kind_stays_info():
    assert classify(obs("something_invented", 999), TABLE.get("something_invented", {})) == "info"


def test_apply_sets_severity_and_threshold():
    items = [obs("disk_usage", 95), obs("disk_usage", 10, subject="nuc")]
    apply(items, RULES)
    assert items[0].severity == "crit"
    assert items[0].threshold == 90
    assert items[1].severity == "info"


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        try:
            fn()
            print("PASS %s" % name)
        except AssertionError as exc:
            failures += 1
            print("FAIL %s: %s" % (name, exc))
    print("\n%d failure(s)" % failures)
    sys.exit(1 if failures else 0)
