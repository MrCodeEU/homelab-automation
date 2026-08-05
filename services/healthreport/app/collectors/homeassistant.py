"""Home Assistant health via its Core REST API.

No SSH: HAOS restricts shell access, and this install's Supervisor API isn't
exposed to the report. Core's REST API is the stable surface available
either way - safe_mode tells us the box is limping, and unavailable/unknown
entity states are the one signal that reliably says "an integration or
device broke" without needing per-integration knowledge.
"""

import re
from collections import Counter

from ..model import CollectorResult, Observation
from .base import collector, http_get

# Domains where "unknown" is the resting state, not a fault. A button entity is
# a trigger, not a measurement: HA stores the timestamp of the last press, so a
# button nobody has pressed reads "unknown" forever. Same for the service-shaped
# domains, and for events until one fires. Counting these meant the metric could
# never reach zero, which is why the thresholds had to be raised to 700/750 and
# stopped being able to detect anything.
UNKNOWN_IS_NORMAL = (
    "button", "scene", "script", "input_button", "notify", "tts",
    "conversation", "event", "stt", "image",
)

# Entities are named <domain>.<integration-ish prefix>_<rest>. There is no
# integration field in the REST API (config entries are websocket-only), so the
# grouping is heuristic: the first two underscore-separated tokens. Good enough
# to turn "467 dead entities" into "1 dead integration", which is the number a
# human can act on.
CLUSTER_TOKENS = 2

# A cluster this size or larger is an integration or device that fell over. Below
# it is almost always a phone, laptop or PC that is simply switched off - this
# estate has ~49 such clusters at any time, each contributing one device_tracker
# and one switch. Counting those makes the metric track how many people are out
# of the house, which is not a health signal.
SIGNIFICANT_CLUSTER = 5


def _headers(config):
    return {"Authorization": "Bearer %s" % config.ha_token}


def _cluster(entity_id: str) -> str:
    obj = entity_id.split(".", 1)[-1]
    return "_".join(obj.split("_")[:CLUSTER_TOKENS])


def is_real_fault(state: dict) -> bool:
    """Is this entity's state a fault, rather than a normal resting value?"""
    value = state.get("state")
    if value not in ("unavailable", "unknown"):
        return False
    domain = state.get("entity_id", "").split(".", 1)[0]
    if value == "unknown" and domain in UNKNOWN_IS_NORMAL:
        return False
    return True


@collector("homeassistant")
def collect(config, rules):
    result = CollectorResult(name="homeassistant")
    obs = result.observations

    if not config.ha_token:
        result.status = "unavailable"
        result.error = "no Home Assistant token configured (secrets.homeassistant.token)"
        return result

    base = config.ha_url.rstrip("/")
    headers = _headers(config)

    ha_config = http_get(base + "/api/config", headers=headers, timeout=20).json()
    states = http_get(base + "/api/states", headers=headers, timeout=20).json()

    state = ha_config.get("state")
    safe_mode = ha_config.get("safe_mode")
    if safe_mode or (state and state != "RUNNING"):
        obs.append(Observation(
            id="ha_safe_mode.homeassistant.",
            collector="homeassistant",
            subject="homeassistant",
            kind="ha_safe_mode",
            value=state or "safe_mode",
            message="Home Assistant is not in a normal running state (state=%s, safe_mode=%s)"
                    % (state, safe_mode),
            evidence={"version": ha_config.get("version")},
        ))

    # Raw count is kept for the trend line, but the finding is built from real
    # faults only - see UNKNOWN_IS_NORMAL.
    raw_unavailable = [s for s in states if s.get("state") in ("unavailable", "unknown")]
    faults = [s for s in states if is_real_fault(s)]

    # One broken integration can produce hundreds of dead entities: a single
    # expired Strava token accounted for 467 of 704 here. Reporting entities
    # makes that look like 467 problems; reporting clusters makes it one.
    clusters = Counter(_cluster(s["entity_id"]) for s in faults)
    significant = {name: n for name, n in clusters.items() if n >= SIGNIFICANT_CLUSTER}
    worst = sorted(significant.items(), key=lambda kv: -kv[1])[:10]

    obs.append(Observation(
        id="ha_unavailable_entities.homeassistant.",
        collector="homeassistant",
        subject="homeassistant",
        kind="ha_unavailable_entities",
        value=len(significant),
        unit="integrations",
        threshold=SIGNIFICANT_CLUSTER,
        message="%d Home Assistant integration(s)/device(s) down with %d+ dead entities each: %s"
                % (len(significant), SIGNIFICANT_CLUSTER,
                   ", ".join("%s (%d)" % (n, c) for n, c in worst[:4]) or "none"),
        evidence={
            "clusters": ["%s (%d)" % (name, n) for name, n in worst],
            "total_fault_entities": len(faults),
            "small_clusters": len(clusters) - len(significant),
            "excluded_normal_unknown": len(raw_unavailable) - len(faults),
        },
    ))

    # Pending updates, informational. HA surfaces these as update.* entities
    # whose state is "on" when an upgrade is waiting.
    pending = []
    for s in states:
        if s.get("entity_id", "").startswith("update.") and s.get("state") == "on":
            attrs = s.get("attributes", {})
            pending.append({
                "name": attrs.get("friendly_name") or s["entity_id"],
                "installed": attrs.get("installed_version"),
                "latest": attrs.get("latest_version"),
            })
    if pending:
        obs.append(Observation(
            id="ha_updates_available.homeassistant.",
            collector="homeassistant",
            subject="homeassistant",
            kind="ha_updates_available",
            value=len(pending),
            unit="updates",
            message="%d Home Assistant update(s) available: %s"
                    % (len(pending), ", ".join(p["name"] for p in pending[:4])),
            evidence={"updates": pending},
        ))

    result.data = {
        "version": ha_config.get("version"),
        "core_state": ha_config.get("state"),
        "entity_count": len(states),
        "unavailable_count": len(faults),
        "raw_unavailable_count": len(raw_unavailable),
        "clusters": ["%s (%d)" % (name, n) for name, n in worst],
        "updates_available": pending,
    }
    return result
