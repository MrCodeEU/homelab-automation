"""Maintenance-window suppression for traffic-derived findings.

The failure this prevents: the Unraid appdata backup stops thirteen containers
every Sunday morning and produces thousands of 5xx. Reported flat, that is
indistinguishable from an outage, and the number stops meaning anything.
"""

import os
import sys
import time
import types

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

sys.modules.setdefault("requests", types.ModuleType("requests"))

from app.collectors.loki import (           # noqa: E402
    in_window, parse_windows, split_maintenance,
)


def at(year, month, day, hour, minute=0):
    """Local-time timestamp, so these tests do not depend on the host's TZ."""
    return int(time.mktime((year, month, day, hour, minute, 0, 0, 0, -1)))


# 2026-08-02 is a Sunday; asserted rather than assumed.
SUNDAY = at(2026, 8, 2, 12)
assert time.localtime(SUNDAY).tm_wday == 6, "fixture date is not a Sunday"


def test_parse_valid_windows():
    got = parse_windows(["daily 00:00-00:10", "sun 04:55-08:00"])
    assert got == [(None, 0, 10), (6, 295, 480)], got


def test_parse_drops_garbage_without_raising():
    got = parse_windows(["nonsense", "sun 25:00", "", "mon 01:00-02:00"])
    assert got == [(0, 60, 120)], got


def test_daily_window_matches_any_weekday():
    windows = parse_windows(["daily 00:00-00:10"])
    assert in_window(time.localtime(at(2026, 7, 29, 0, 5)), windows)
    assert in_window(time.localtime(at(2026, 8, 2, 0, 5)), windows)
    assert not in_window(time.localtime(at(2026, 7, 29, 0, 30)), windows)


def test_weekday_window_only_matches_that_day():
    windows = parse_windows(["sun 04:55-08:00"])
    assert in_window(time.localtime(at(2026, 8, 2, 6)), windows)
    # Same hour, Saturday.
    assert not in_window(time.localtime(at(2026, 8, 1, 6)), windows)


def test_window_end_is_exclusive():
    windows = parse_windows(["sun 04:55-08:00"])
    assert in_window(time.localtime(at(2026, 8, 2, 7, 59)), windows)
    assert not in_window(time.localtime(at(2026, 8, 2, 8, 0)), windows)


def test_window_wrapping_midnight():
    windows = parse_windows(["sat 23:00-01:00"])
    assert in_window(time.localtime(at(2026, 8, 1, 23, 30)), windows)   # Sat late
    assert in_window(time.localtime(at(2026, 8, 2, 0, 30)), windows)    # Sun early
    assert not in_window(time.localtime(at(2026, 8, 2, 1, 30)), windows)


def test_split_judges_bucket_by_the_hour_it_covers():
    """count_over_time([1h]) stamps a bucket at the END of the hour it covers,
    so the 06:00 sample is the 05:00-06:00 traffic and must be suppressed."""
    windows = parse_windows(["sun 04:55-08:00"])
    series = [
        (at(2026, 8, 2, 5), 10.0),    # covers 04:00-05:00 -> outside
        (at(2026, 8, 2, 6), 2619.0),  # covers 05:00-06:00 -> inside
        (at(2026, 8, 2, 8), 3071.0),  # covers 07:00-08:00 -> inside
        (at(2026, 8, 2, 9), 182.0),   # covers 08:00-09:00 -> outside
    ]
    kept, suppressed = split_maintenance(series, windows)
    assert [v for _t, v in kept] == [10.0, 182.0], kept
    assert [v for _t, v in suppressed] == [2619.0, 3071.0], suppressed


def test_no_windows_keeps_everything():
    series = [(at(2026, 8, 2, 6), 5.0), (at(2026, 8, 2, 7), 7.0)]
    kept, suppressed = split_maintenance(series, [])
    assert len(kept) == 2 and suppressed == []


def test_real_sunday_shape_is_no_longer_an_incident():
    """Observed 07-26: baseline ~180/h, three bad hours during the backup."""
    windows = parse_windows(["sun 04:55-08:00"])
    series = [(at(2026, 7, 26, h), v) for h, v in [
        (3, 195.0), (4, 180.0), (5, 183.0),
        (6, 2619.0), (7, 3063.0), (8, 3071.0),
        (9, 182.0), (10, 184.0),
    ]]
    kept, suppressed = split_maintenance(series, windows)
    assert int(sum(v for _t, v in suppressed)) == 8753
    bad_hours = [v for _t, v in kept if v >= 100]
    # Everything left is the flat dead-vhost baseline, not a spike.
    assert max(bad_hours) < 200, bad_hours


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
