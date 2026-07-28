"""Core data types shared by collectors, severity rules and the diff.

An Observation is the atomic unit of the report. Its `id` is deliberately
value-free (`<kind>.<subject>.<resource>`) so that the same underlying problem
maps to the same id on every run - that is what makes "new since yesterday"
and "broken for six days" derivable instead of guessed.
"""

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

SEVERITIES = ("info", "warn", "crit")


def severity_rank(severity: str) -> int:
    try:
        return SEVERITIES.index(severity)
    except ValueError:
        return 0


def worst(severities) -> str:
    ranked = [s for s in severities if s in SEVERITIES]
    if not ranked:
        return "info"
    return max(ranked, key=severity_rank)


@dataclass
class Observation:
    id: str
    collector: str
    subject: str
    kind: str
    message: str
    severity: str = "info"
    value: Optional[Any] = None
    unit: Optional[str] = None
    threshold: Optional[Any] = None
    evidence: Dict[str, Any] = field(default_factory=dict)
    # Filled in by the diff stage from the previous run's state.
    first_seen: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class CollectorResult:
    name: str
    status: str = "ok"          # ok | error | unavailable
    error: Optional[str] = None
    duration_s: float = 0.0
    data: Optional[Any] = None
    observations: List[Observation] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "status": self.status,
            "error": self.error,
            "duration_s": round(self.duration_s, 3),
            "data": self.data,
        }
