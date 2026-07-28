"""Markdown rendering for the report body and the ntfy headline."""

import os

from jinja2 import Environment, FileSystemLoader, select_autoescape

from .model import severity_rank

TEMPLATE_DIR = os.environ.get("HEALTHREPORT_TEMPLATES", "/app/templates")


def _env():
    return Environment(
        loader=FileSystemLoader(TEMPLATE_DIR),
        autoescape=select_autoescape(enabled_extensions=("html",)),
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )


def summary_counts(facts):
    summary = facts["summary"]
    parts = []
    for level in ("crit", "warn"):
        if summary.get(level):
            parts.append("%d %s" % (summary[level], level))
    if not parts:
        parts.append("all clear")
    diff = facts["diff"]
    parts.append("%d new" % len(diff["new"]))
    if diff["resolved"]:
        parts.append("%d resolved" % len(diff["resolved"]))
    return " · ".join(parts)


def _worst_new(facts, by_id):
    candidates = [by_id[i] for i in facts["diff"]["new"] if i in by_id]
    if not candidates:
        return None
    return max(candidates, key=lambda o: severity_rank(o["severity"]))


def render(facts, narrative):
    env = _env()
    by_id = {obs["id"]: obs for obs in facts["observations"]}

    fallback = env.get_template("summary_fallback.md.j2").render(
        facts=facts, worst_new=_worst_new(facts, by_id),
    ).strip()

    body = env.get_template("report.md.j2").render(
        facts=facts,
        narrative=narrative,
        by_id=by_id,
        fallback=fallback,
        summary_counts=summary_counts(facts),
    )
    return body, fallback


def headline(facts, narrative, fallback):
    if narrative and narrative.get("headline"):
        return narrative["headline"]
    # First line of the mechanical summary, stripped of Markdown emphasis.
    return fallback.splitlines()[0].replace("**", "") if fallback else "Homelab health"


def ntfy_body(facts, narrative, fallback, limit=5):
    by_id = {obs["id"]: obs for obs in facts["observations"]}
    lines = [summary_counts(facts)]

    highlights = facts["diff"]["new"] or facts["diff"]["persisting"]
    for obs_id in highlights[:limit]:
        obs = by_id.get(obs_id)
        if obs:
            lines.append("%s %s" % (obs["severity"].upper(), obs["message"]))

    if facts["summary"].get("collectors_failed"):
        lines.append("collectors failed: %s" % ", ".join(facts["summary"]["collectors_failed"]))
    return "\n".join(lines)[:3800]
