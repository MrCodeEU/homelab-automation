"""Ollama triage narrative.

The model groups, ranks and explains. It never decides severity - that is
already fixed by rules.yml before this module is called, and any severity-like
key in the response is stripped.

Contract, in a try/finally so a crash cannot leave the model resident in NAS
RAM: load -> generate -> unload.
"""

import json
import logging

import requests

LOG = logging.getLogger("healthreport.llm")

# Floor for loading the model into RAM, independent of the generation budget.
# An 8B model read cold off the NAS array takes minutes; warm it is ~24s.
LOAD_TIMEOUT_S = 600

RESPONSE_SCHEMA = {
    "type": "object",
    "required": ["headline", "assessment", "top_issues", "suggested_actions"],
    "properties": {
        "headline": {"type": "string", "maxLength": 120},
        "assessment": {"type": "string", "maxLength": 1200},
        "top_issues": {
            "type": "array",
            "maxItems": 3,
            "items": {
                "type": "object",
                "required": ["observation_id", "why_it_matters"],
                "properties": {
                    "observation_id": {"type": "string"},
                    "why_it_matters": {"type": "string", "maxLength": 300},
                },
            },
        },
        "suggested_actions": {
            "type": "array",
            "maxItems": 5,
            "items": {"type": "string", "maxLength": 200},
        },
        "correlations": {
            "type": "array",
            "maxItems": 3,
            "items": {"type": "string", "maxLength": 200},
        },
    },
}

SYSTEM_PROMPT = """You are the triage step of an automated homelab health report.

The observations you receive have ALREADY been classified by deterministic
rules. You must not re-judge them:
- Never state or imply a different severity than the one given.
- Never invent hosts, services, metrics or numbers that are not in the input.
- Only reference observations by an observation_id that appears in the input.

Your job is to group related findings, pick the three that most deserve
attention, explain briefly why they matter, and suggest concrete next steps.

Each finding is an object with an "observation_id" field. When you reference a
finding, copy that field's value exactly and nothing else - no severity, no
message text appended.
Be terse and factual. No pleasantries, no filler, no speculation about causes
you cannot support from the data.

The headline is the push-notification title and must name the single most
important concrete thing, e.g. "nas cache filling, 2 monitors down". Never a
generic label like "Top 3 Critical Findings" or "System Health Summary". The
assessment must say what changed and what it means - not restate that the
findings deserve attention.

Reply with JSON conforming to the given schema and nothing else."""

# Keys that would let the model smuggle a severity judgement back in.
FORBIDDEN_KEYS = {"severity", "level", "priority", "crit", "warn", "status", "verdict"}


class LLMUnavailable(Exception):
    pass


def _post(config, path, payload, timeout):
    response = requests.post(
        config.ollama_url.rstrip("/") + path, json=payload, timeout=timeout,
    )
    response.raise_for_status()
    return response.json()


def load(config):
    """Empty prompt loads the model into memory without generating.

    Given its own, larger budget than a generation. Reading 5GB of weights off
    disk into RAM is one-off and slow, and is not the thing the generation
    timeout is protecting against - a cold load on the NAS is minutes, a warm
    one is ~24 seconds. Capping this at the generation timeout meant the daily
    run aborted the load at 3m01s (ollama logged HTTP 499, "client connection
    closed before llama-server finished loading") whenever the model was not
    already resident, which is every morning after an overnight restart.
    """
    _post(config, "/api/generate",
          {"model": config.ollama_model, "prompt": "", "keep_alive": "10m"},
          timeout=max(config.llm_timeout_s, LOAD_TIMEOUT_S))


def unload(config):
    """keep_alive 0 evicts immediately - equivalent to `ollama stop`."""
    try:
        _post(config, "/api/generate",
              {"model": config.ollama_model, "prompt": "", "keep_alive": 0},
              timeout=60)
    except Exception as exc:
        # Never fail the report because cleanup failed; OLLAMA_KEEP_ALIVE=30s
        # on the container is the backstop.
        LOG.warning("could not unload model: %s", exc)


def build_input(facts):
    """Compact the facts into ~2k tokens: identity plus message, no payloads."""
    by_id = {obs["id"]: obs for obs in facts["observations"]}

    def render(ids):
        """Structured, not a concatenated string.

        Rendering these as "<id> [sev] <message>" made the model copy the whole
        line back as observation_id, so every one of its picks was dropped by
        the id check. Keeping the id in its own field removes the ambiguity.
        """
        out = []
        for obs_id in ids:
            obs = by_id.get(obs_id)
            if obs:
                out.append({
                    "observation_id": obs_id,
                    "severity": obs["severity"],
                    "message": obs["message"],
                })
        return out

    diff = facts["diff"]
    return {
        "date": facts["run"]["id"],
        "counts": facts["summary"],
        "new": render(diff["new"]),
        "reopened": render(diff["reopened"]),
        "worsened": [
            {
                "observation_id": w["id"],
                "from": w["from"],
                "to": w["to"],
                "message": by_id.get(w["id"], {}).get("message", ""),
            }
            for w in diff["worsened"]
        ],
        "persisting_count": len(diff["persisting"]),
        "persisting_sample": render(diff["persisting"][:10]),
        "resolved": render(diff["resolved"]),
        "failed_collectors": facts["summary"].get("collectors_failed", []),
    }


def _strip(payload):
    """Recursively drop severity-like keys from the model's response."""
    if isinstance(payload, dict):
        return {k: _strip(v) for k, v in payload.items() if k.lower() not in FORBIDDEN_KEYS}
    if isinstance(payload, list):
        return [_strip(v) for v in payload]
    return payload


def validate(payload, valid_ids):
    """Enforce the contract. Raises ValueError if the response is unusable."""
    if not isinstance(payload, dict):
        raise ValueError("response is not an object")

    payload = _strip(payload)

    headline = payload.get("headline")
    assessment = payload.get("assessment")
    if not isinstance(headline, str) or not headline.strip():
        raise ValueError("missing headline")
    if not isinstance(assessment, str) or not assessment.strip():
        raise ValueError("missing assessment")

    issues = []
    for issue in payload.get("top_issues") or []:
        if not isinstance(issue, dict):
            continue
        obs_id = issue.get("observation_id")
        # Anti-hallucination: an id the run never produced is dropped outright.
        if obs_id not in valid_ids:
            LOG.warning("dropping unknown observation_id from LLM output: %r", obs_id)
            continue
        issues.append({
            "observation_id": obs_id,
            "why_it_matters": str(issue.get("why_it_matters", ""))[:300],
        })

    actions = [str(a)[:200] for a in (payload.get("suggested_actions") or [])
               if isinstance(a, (str, int, float))][:5]
    correlations = [str(c)[:200] for c in (payload.get("correlations") or [])
                    if isinstance(c, (str, int, float))][:3]

    return {
        "headline": headline.strip()[:120],
        "assessment": assessment.strip()[:1200],
        "top_issues": issues[:3],
        "suggested_actions": actions,
        "correlations": correlations,
    }


def summarize(config, facts):
    """Return (narrative, status). Never raises."""
    if not config.llm_enabled:
        return None, "disabled"

    valid_ids = {obs["id"] for obs in facts["observations"]}
    payload_in = build_input(facts)

    try:
        load(config)
    except Exception as exc:
        LOG.warning("ollama unavailable: %s", exc)
        return None, "unavailable"

    try:
        for attempt, temperature in enumerate((0.2, 0.0)):
            payload = {
                "model": config.ollama_model,
                "stream": False,
                "format": RESPONSE_SCHEMA,
                "keep_alive": "10m",
                "options": {"temperature": temperature, "num_ctx": 8192},
                # qwen3 is a reasoning model and emits a long <think> block by
                # default. On NAS CPU that alone blew past a 180s budget and
                # every run degraded to "unavailable". The report needs a
                # summary, not visible deliberation.
                "think": False,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": json.dumps(payload_in, indent=1)},
                ] + ([{"role": "user",
                       "content": "Your last reply was not valid JSON for the schema. "
                                  "Reply with schema-conforming JSON only."}]
                     if attempt else []),
            }
            try:
                response = _post(config, "/api/chat", payload, timeout=config.llm_timeout_s)
            except requests.exceptions.HTTPError as exc:
                # Models that do not support thinking reject the field outright.
                status = getattr(exc.response, "status_code", None)
                if status == 400 and "think" in payload:
                    LOG.info("model does not accept 'think'; retrying without it")
                    payload.pop("think")
                    try:
                        response = _post(config, "/api/chat", payload,
                                         timeout=config.llm_timeout_s)
                    except requests.exceptions.RequestException as inner:
                        LOG.warning("ollama request failed: %s", inner)
                        return None, "unavailable"
                else:
                    LOG.warning("ollama request failed: %s", exc)
                    return None, "unavailable"
            except requests.exceptions.RequestException as exc:
                LOG.warning("ollama request failed: %s", exc)
                return None, "unavailable"

            content = (response.get("message") or {}).get("content", "")
            try:
                return validate(json.loads(content), valid_ids), "ok"
            except (ValueError, TypeError) as exc:
                LOG.warning("attempt %d produced unusable output: %s", attempt + 1, exc)

        return None, "degraded_invalid"
    finally:
        unload(config)
