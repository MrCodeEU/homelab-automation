"""The diff is what turns a status page into something that catches silent
failures. These tests pin the distinctions that matter: new vs reopened vs
persisting, and severity transitions."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.diff import compute      # noqa: E402
from app.model import Observation  # noqa: E402

NOW = "2026-07-28T06:00:00+02:00"
YESTERDAY = "2026-07-27T06:00:00+02:00"


def obs(obs_id, severity="warn"):
    return Observation(
        id=obs_id, collector="test", subject="mljr", kind="disk_usage",
        message=obs_id, severity=severity,
    )


def previous_facts(*pairs):
    return {"observations": [{"id": i, "severity": s} for i, s in pairs]}


def test_brand_new_issue():
    result = compute([obs("a")], {}, {}, NOW)
    assert result["new"] == ["a"], result
    assert result["persisting"] == []


def test_persisting_issue_keeps_first_seen():
    seen = {"a": {"first_seen": YESTERDAY, "last_seen": YESTERDAY,
                  "count": 1, "last_actionable_run": YESTERDAY, "severity": "warn"}}
    item = obs("a")
    result = compute([item], previous_facts(("a", "warn")), seen, NOW)
    assert result["new"] == []
    assert result["persisting"] == ["a"]
    assert item.first_seen == YESTERDAY, "first_seen must survive so age is derivable"


def test_resolved_is_reported():
    result = compute([], previous_facts(("a", "crit")), {}, NOW)
    assert result["resolved"] == ["a"]


def test_reopened_is_not_new():
    # Known before, cleared, now back. A flapping problem needs different
    # attention than a fresh one.
    seen = {"a": {"first_seen": "2026-07-01T06:00:00+02:00", "last_seen": YESTERDAY,
                  "count": 3, "last_actionable_run": YESTERDAY, "severity": "warn",
                  "resolved_at": YESTERDAY}}
    result = compute([obs("a")], {"observations": []}, seen, NOW)
    assert result["reopened"] == ["a"], result
    assert result["new"] == []


def test_worsened_and_improved():
    result = compute([obs("a", "crit")], previous_facts(("a", "warn")), {}, NOW)
    assert result["worsened"] == [{"id": "a", "from": "warn", "to": "crit"}]

    result = compute([obs("b", "warn")], previous_facts(("b", "crit")), {}, NOW)
    assert result["improved"] == [{"id": "b", "from": "crit", "to": "warn"}]


def test_info_observations_are_not_actionable():
    # An info-level observation existing yesterday must not stop the same id
    # counting as new when it escalates to warn today.
    result = compute([obs("a", "warn")], previous_facts(("a", "info")), {}, NOW)
    assert result["new"] == ["a"], result


def test_info_still_recorded_in_seen():
    seen = {}
    compute([obs("a", "info")], {}, seen, NOW)
    assert "a" in seen, "new_only rules depend on info observations being tracked"
    assert seen["a"]["last_actionable_run"] is None


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
