"""Home Assistant health via its Core REST API.

No SSH: HAOS restricts shell access, and this install's Supervisor API isn't
exposed to the report. Core's REST API is the stable surface available
either way - safe_mode tells us the box is limping, and unavailable/unknown
entity states are the one signal that reliably says "an integration or
device broke" without needing per-integration knowledge.
"""

from ..model import CollectorResult, Observation
from .base import collector, http_get


def _headers(config):
    return {"Authorization": "Bearer %s" % config.ha_token}


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

    unavailable = [s for s in states if s.get("state") in ("unavailable", "unknown")]
    obs.append(Observation(
        id="ha_unavailable_entities.homeassistant.",
        collector="homeassistant",
        subject="homeassistant",
        kind="ha_unavailable_entities",
        value=len(unavailable),
        unit="entities",
        message="%d Home Assistant entities are unavailable or unknown" % len(unavailable),
        evidence={"sample": [s.get("entity_id") for s in unavailable[:20]]},
    ))

    result.data = {
        "version": ha_config.get("version"),
        "core_state": ha_config.get("state"),
        "entity_count": len(states),
        "unavailable_count": len(unavailable),
        "unavailable_sample": [s.get("entity_id") for s in unavailable[:50]],
    }
    return result
