"""Trend series for the HTML report.

Reads the retained daily facts files so the email can show whether things are
getting better or worse, which a single day's counts cannot say.
"""

import json
import os
import re
from typing import Dict, List

FILENAME = re.compile(r"^facts-(\d{4})(\d{2})(\d{2})\.json$")


def trend(state_dir: str, days: int = 10) -> List[Dict]:
    """Return [{date, crit, warn}] oldest-first for the last `days` files."""
    history_dir = os.path.join(state_dir, "history")
    try:
        names = sorted(n for n in os.listdir(history_dir) if FILENAME.match(n))
    except OSError:
        return []

    out = []
    for name in names[-days:]:
        match = FILENAME.match(name)
        try:
            with open(os.path.join(history_dir, name)) as fh:
                facts = json.load(fh)
        except (OSError, ValueError):
            continue
        summary = facts.get("summary", {})
        out.append({
            "date": "%s-%s" % (match.group(2), match.group(3)),
            "crit": int(summary.get("crit", 0)),
            "warn": int(summary.get("warn", 0)),
        })
    return out


def by_host(facts: Dict) -> List[Dict]:
    """Actionable findings per subject, worst first.

    Subjects are hosts for most collectors but also repos and monitor names;
    that is the useful grouping - it answers "where is the trouble".
    """
    counts = {}
    for obs in facts.get("observations", []):
        severity = obs.get("severity")
        if severity not in ("crit", "warn"):
            continue
        entry = counts.setdefault(obs.get("subject") or "unknown", {"crit": 0, "warn": 0})
        entry[severity] += 1

    rows = [
        {"subject": subject, "crit": v["crit"], "warn": v["warn"], "total": v["crit"] + v["warn"]}
        for subject, v in counts.items()
    ]
    # Critical count dominates the ordering: three warnings are not worse than
    # one outage.
    rows.sort(key=lambda r: (-r["crit"], -r["total"], r["subject"]))
    return rows
