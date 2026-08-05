"""Markdown rendering for the report body and the ntfy headline."""

import os

from jinja2 import Environment, FileSystemLoader

from . import history, system_state
from .model import severity_rank

TEMPLATE_DIR = os.environ.get("HEALTHREPORT_TEMPLATES", "/app/templates")


def _autoescape(template_name):
    """Escape anything HTML, including the .html.j2 double extension.

    select_autoescape's extension match looks at the final suffix only, so
    "report.html.j2" would render unescaped. That matters here: normalized log
    signatures contain literal <ts>, <path>, <n> and <ip> placeholders, which a
    mail client would silently swallow as unknown tags - and arbitrary log text
    would be injected into the markup.
    """
    return bool(template_name) and ".html" in template_name


def _env():
    return Environment(
        loader=FileSystemLoader(TEMPLATE_DIR),
        autoescape=_autoescape,
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


def render_html(facts, narrative, headline, state_dir):
    """HTML part of the email.

    Charts are table cells with background colours, because email clients have
    no JavaScript and several strip SVG. Severity uses the reserved status
    palette; `warning` is sub-3:1 on a light surface by design, so every
    segment carries a visible number and the full table is always present -
    colour never carries meaning alone.
    """
    env = _env()
    by_id = {obs["id"]: obs for obs in facts["observations"]}
    summary = facts["summary"]
    diff = facts["diff"]

    def rows(ids):
        return [by_id[i] for i in ids if i in by_id]

    sections = [
        {"title": "New today", "rows": rows(diff["new"]), "show_age": False},
        {"title": "Reopened", "rows": rows(diff["reopened"]), "show_age": True},
        {"title": "Still open", "rows": rows(diff["persisting"]), "show_age": True},
    ]

    hosts = history.by_host(facts)
    trend_points = history.trend(state_dir)
    state = {
        "hosts": system_state.hosts(facts),
        "counts": system_state.counts(facts),
        "notes": system_state.notes(facts),
        "backup_targets": system_state.backup_targets(facts),
    }

    return env.get_template("report.html.j2").render(
        facts=facts,
        narrative=narrative,
        headline=headline,
        sections=sections,
        by_host=hosts,
        # Guard every denominator: a clean run has zero of everything.
        host_max=max([r["total"] for r in hosts] or [1]) or 1,
        trend=trend_points,
        trend_max=max([p["crit"] + p["warn"] for p in trend_points] or [1]) or 1,
        trend_height=90,
        state=state,
        tiles=[
            {"label": "Critical", "value": summary.get("crit", 0), "color": "#d03b3b"},
            {"label": "Warnings", "value": summary.get("warn", 0), "color": "#fab219"},
            {"label": "New", "value": len(diff["new"]), "color": "#0b0b0b"},
            {"label": "Resolved", "value": len(diff["resolved"]), "color": "#0ca30c"},
        ],
    )


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
