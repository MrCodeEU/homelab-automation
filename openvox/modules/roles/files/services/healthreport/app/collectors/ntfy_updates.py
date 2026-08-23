"""Pending container image updates.

Diun already watches every image and publishes to ntfy on a 6h schedule
(services/diun/diun.yml). Reading its topic back costs nothing and avoids a
second registry-polling implementation.
"""

import json

from ..model import CollectorResult, Observation
from .base import collector, http_get


@collector("updates")
def collect(config, rules):
    result = CollectorResult(name="updates")
    obs = result.observations

    response = http_get(
        "%s/docker-updates/json" % config.ntfy_url.rstrip("/"),
        params={"poll": "1", "since": "%dh" % config.lookback_hours},
        timeout=30,
    )

    # ntfy streams newline-delimited JSON, one message per line.
    messages = []
    for line in response.text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("event") != "message":
            continue
        messages.append({
            "title": message.get("title", ""),
            "message": (message.get("message") or "")[:300],
            "time": message.get("time"),
        })

    result.data = {"count": len(messages), "messages": messages[:50]}
    obs.append(Observation(
        id="image_updates..",
        collector="updates",
        subject="homelab",
        kind="image_updates",
        value=len(messages),
        unit="images",
        message="%d container image update notifications in the last %dh"
                % (len(messages), config.lookback_hours),
        evidence={"topic": "docker-updates"},
    ))
    return result
