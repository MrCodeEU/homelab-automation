"""Day-over-day diff and long-lived seen-state.

This is the part that catches silent failures. Current state alone cannot tell
you that a backup has been failing for four days, or that an error signature
appeared today for the first time. Both fall out of comparing identities
across runs.

Identity is the observation `id`, which is value-free by construction, so the
same underlying problem keeps the same id as its value fluctuates.
"""

import json
import os
from typing import Dict, List

from .model import Observation, severity_rank

STATE_FILE_LATEST = "facts-latest.json"
STATE_FILE_PREVIOUS = "facts-previous.json"
SEEN_FILE = "seen/observations.json"


def _read_json(path, default):
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def load_previous(state_dir: str) -> Dict:
    return _read_json(os.path.join(state_dir, STATE_FILE_LATEST), {})


def load_seen(state_dir: str) -> Dict:
    return _read_json(os.path.join(state_dir, SEEN_FILE), {})


def previous_ids(previous: Dict) -> set:
    """Ids that were actionable last run.

    Only warn/crit count. An observation that merely existed at info level was
    not a problem, so its reappearance at warn level is genuinely new.
    """
    return {
        entry["id"]
        for entry in previous.get("observations", [])
        if entry.get("severity") in ("warn", "crit")
    }


def compute(observations: List[Observation], previous: Dict, seen: Dict, now_iso: str) -> Dict:
    """Compare this run against the last and update the seen-state in place."""
    previous_by_id = {
        entry["id"]: entry for entry in previous.get("observations", [])
    }

    current_actionable = {
        obs.id: obs for obs in observations if obs.severity in ("warn", "crit")
    }
    previous_actionable = previous_ids(previous)

    new, reopened, worsened, improved, persisting = [], [], [], [], []

    for obs_id, obs in current_actionable.items():
        record = seen.get(obs_id)
        previous_entry = previous_by_id.get(obs_id)
        was_actionable = obs_id in previous_actionable

        if was_actionable:
            persisting.append(obs_id)
            before = (previous_entry or {}).get("severity", "info")
            if severity_rank(obs.severity) > severity_rank(before):
                worsened.append({"id": obs_id, "from": before, "to": obs.severity})
            elif severity_rank(obs.severity) < severity_rank(before):
                improved.append({"id": obs_id, "from": before, "to": obs.severity})
        elif record and record.get("last_actionable_run"):
            # Known before, cleared, and back again. Distinct from brand new:
            # a flapping problem needs different attention than a fresh one.
            reopened.append(obs_id)
        else:
            new.append(obs_id)

        if record:
            obs.first_seen = record.get("first_seen", now_iso)
            record["last_seen"] = now_iso
            record["count"] = record.get("count", 0) + 1
            record["last_actionable_run"] = now_iso
            record["severity"] = obs.severity
        else:
            obs.first_seen = now_iso
            seen[obs_id] = {
                "first_seen": now_iso,
                "last_seen": now_iso,
                "count": 1,
                "last_actionable_run": now_iso,
                "severity": obs.severity,
                "kind": obs.kind,
                "subject": obs.subject,
            }

    resolved = sorted(previous_actionable - set(current_actionable))
    for obs_id in resolved:
        record = seen.get(obs_id)
        if record:
            record["resolved_at"] = now_iso

    # Non-actionable observations still need first_seen carried, and their
    # identity recorded, so `new_only` rules (log signatures) work at all.
    for obs in observations:
        if obs.id in current_actionable:
            continue
        record = seen.get(obs.id)
        if record:
            obs.first_seen = record.get("first_seen", now_iso)
            record["last_seen"] = now_iso
            record["count"] = record.get("count", 0) + 1
        else:
            obs.first_seen = now_iso
            seen[obs.id] = {
                "first_seen": now_iso,
                "last_seen": now_iso,
                "count": 1,
                "last_actionable_run": None,
                "severity": obs.severity,
                "kind": obs.kind,
                "subject": obs.subject,
            }

    return {
        "new": sorted(new),
        "reopened": sorted(reopened),
        "worsened": worsened,
        "improved": improved,
        "resolved": resolved,
        "persisting": sorted(persisting),
    }


def first_run_ids(state_dir: str) -> set:
    """Ids already known, used to decide `new_only` severities.

    On the very first run nothing is known, so every signature would look new
    and the report would be pure noise. Returning an empty set on a missing
    seen-file makes main.py suppress new_only escalation for that run.
    """
    return set(load_seen(state_dir).keys())


def save(state_dir: str, facts: Dict, seen: Dict, history_days: int = 30) -> None:
    os.makedirs(os.path.join(state_dir, "history"), exist_ok=True)
    os.makedirs(os.path.join(state_dir, "seen"), exist_ok=True)

    latest = os.path.join(state_dir, STATE_FILE_LATEST)
    previous = os.path.join(state_dir, STATE_FILE_PREVIOUS)
    if os.path.exists(latest):
        os.replace(latest, previous)

    _write(latest, facts)
    _write(os.path.join(state_dir, SEEN_FILE), seen)

    stamp = facts.get("run", {}).get("id", "")[:10].replace("-", "")
    if stamp:
        _write(os.path.join(state_dir, "history", "facts-%s.json" % stamp), facts)
    _prune_history(os.path.join(state_dir, "history"), history_days)


def _write(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True, default=str)
    os.replace(tmp, path)


def _prune_history(directory, keep):
    try:
        files = sorted(f for f in os.listdir(directory) if f.startswith("facts-"))
    except OSError:
        return
    for name in files[:-keep] if len(files) > keep else []:
        try:
            os.remove(os.path.join(directory, name))
        except OSError:
            pass
