"""Deterministic severity classification.

Every observation gets its severity from rules.yml, before the LLM runs. The
model is handed already-classified data and is not permitted to change it -
see llm.py, which strips severity-like keys from the response.
"""

import datetime
from typing import Dict, List, Optional

import yaml

from .model import Observation

FALSE_STRINGS = {"false", "0", "no", "none", "null", ""}


def _age_days(first_seen: Optional[str], now: Optional[datetime.datetime]) -> Optional[float]:
    if not first_seen or now is None:
        return None
    try:
        seen_at = datetime.datetime.fromisoformat(first_seen)
    except ValueError:
        return None
    if seen_at.tzinfo is None and now.tzinfo is not None:
        seen_at = seen_at.replace(tzinfo=now.tzinfo)
    elif seen_at.tzinfo is not None and now.tzinfo is None:
        now = now.replace(tzinfo=seen_at.tzinfo)
    return (now - seen_at).total_seconds() / 86400.0


def load_rules(path: str) -> Dict:
    with open(path, "r") as fh:
        return yaml.safe_load(fh) or {}


def _numeric(value):
    if isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in FALSE_STRINGS


def classify(observation: Observation, rule: Dict, is_new: bool = False,
             now: Optional[datetime.datetime] = None) -> str:
    """Return the severity for one observation. Unknown kinds stay info."""
    if not rule:
        return "info"

    subjects = rule.get("subjects")
    if subjects and observation.subject not in subjects:
        return "info"

    rule_type = rule.get("type")

    if rule_type == "threshold":
        value = _numeric(observation.value)
        if value is None:
            return "info"
        direction = rule.get("direction", "above")
        min_age_days = rule.get("min_age_days")
        for level in ("crit", "warn"):
            limit = rule.get(level)
            if limit is None:
                continue
            limit = float(limit)
            breached = (direction == "above" and value > limit) or \
                       (direction == "below" and value < limit)
            if not breached:
                continue
            if min_age_days is not None:
                # A day-one advisory list is normal; only escalate once it
                # has genuinely sat unresolved (e.g. past the weekly
                # auto-update workflow's own cadence). A brand new
                # observation with no recorded first_seen yet reads as
                # age 0, so it stays info on its first sighting too.
                age = _age_days(observation.first_seen, now)
                if age is None or age < float(min_age_days):
                    return "info"
            observation.threshold = limit
            return level
        return "info"

    if rule_type == "threshold_or_spike":
        # Two independent ways to escalate, whichever fires first.
        #
        # The absolute threshold is deliberately NOT raised to compensate for
        # the spike rule: this widens coverage rather than trading one signal
        # for another. A container that is loud every day keeps reporting, and
        # one that quietly triples while staying under the line now reports too.
        value = _numeric(observation.value)
        if value is None:
            return "info"

        direction = rule.get("direction", "above")
        for level in ("crit", "warn"):
            limit = rule.get(level)
            if limit is None:
                continue
            limit = float(limit)
            if (direction == "above" and value > limit) or \
               (direction == "below" and value < limit):
                observation.threshold = limit
                return level

        previous = _numeric(observation.previous_value)
        factor = float(rule.get("spike_factor", 3.0))
        floor = float(rule.get("spike_floor", 0))
        # A first sighting has no baseline and must not read as a spike, and a
        # previous value of zero would make any growth infinite.
        if previous and previous > 0 and value >= floor and value >= previous * factor:
            # Say why this escalated. Without it the reader sees a number well
            # under the stated threshold and no reason for the warning.
            # (classify already mutates `threshold`, so annotating here is
            # consistent with how the absolute path reports itself.)
            observation.message = "%s — up %.1fx from %s" % (
                observation.message, value / previous, f"{previous:,.0f}",
            )
            return rule.get("spike_level", "warn")

        return "info"

    if rule_type == "equals":
        value = str(observation.value)
        if value in [str(v) for v in rule.get("crit_values", [])]:
            return "crit"
        if value in [str(v) for v in rule.get("warn_values", [])]:
            return "warn"
        return "info"

    if rule_type == "not_equals":
        ok = [str(v) for v in rule.get("ok_values", [])]
        if str(observation.value) not in ok:
            return rule.get("level", "warn")
        return "info"

    if rule_type == "truthy":
        return rule.get("level", "warn") if _truthy(observation.value) else "info"

    if rule_type == "falsy":
        return rule.get("level", "warn") if not _truthy(observation.value) else "info"

    if rule_type == "present":
        return rule.get("level", "warn")

    if rule_type == "new_only":
        # Only interesting the first time it is seen. Steady-state noise stays
        # info so it never reaches the report body.
        return rule.get("level", "warn") if is_new else "info"

    return "info"


def apply(observations: List[Observation], rules: Dict, new_ids=frozenset(),
          now: Optional[datetime.datetime] = None) -> List[Observation]:
    table = (rules or {}).get("rules", {})
    for observation in observations:
        observation.severity = classify(
            observation,
            table.get(observation.kind, {}),
            is_new=observation.id in new_ids,
            now=now,
        )
    return observations
