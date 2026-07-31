"""Log-signature normalization. A signature is an identity: if the same event
produces a different signature on every run, the diff reports it as new every
day and the "new since yesterday" section becomes worthless."""

import os
import sys
import types

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# app.collectors.base imports requests for the HTTP helpers. Normalization is
# pure string work and must stay runnable without the container's dependencies,
# so stub the module rather than requiring it just to import the regexes.
sys.modules.setdefault("requests", types.ModuleType("requests"))

from app.collectors.loki import normalize   # noqa: E402

# Real bichon output: the tracing crate colours its level and target fields.
BICHON = (
    "\x1b[2m2026-07-29T08:05:31.371+00:00\x1b[0m \x1b[31mERROR\x1b[0m "
    "\x1b[2mbichon_server\x1b[0m\x1b[2m:\x1b[0m Documentation: "
    "https://github.com/rustmailer/bichon/wiki"
)


def test_ansi_is_stripped():
    got = normalize(BICHON)
    assert "\x1b" not in got, got
    assert "[31m" not in got, got


def test_timestamp_masked_behind_ansi():
    """The regression this guards: `\\x1b[2m` ends in a word character, so a
    timestamp glued to it has no word boundary and the <ts> rule misses."""
    got = normalize(BICHON)
    assert got.startswith("<ts> ERROR"), got
    assert "2026" not in got, got


def test_same_event_different_timestamps_is_one_signature():
    later = BICHON.replace("08:05:31.371", "09:17:02.884")
    assert normalize(BICHON) == normalize(later)


def test_plain_lines_are_unaffected():
    line = "2026-07-29T08:05:31Z ERROR could not connect to 10.0.0.5:5432"
    got = normalize(line)
    assert got == "<ts> ERROR could not connect to <ip>", got


def test_uncoloured_and_coloured_collapse_together():
    plain = "2026-07-29T08:05:31.371+00:00 ERROR bichon_server: Documentation: https://github.com/rustmailer/bichon/wiki"
    assert normalize(BICHON) == normalize(plain)


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
