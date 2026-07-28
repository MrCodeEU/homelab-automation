"""Delivery: ntfy headline plus the full report by email.

Both are best-effort and independent: a broken SMTP config must not suppress
the push notification, and vice versa. Failures are returned, not raised, so
main.py can report what actually went out.
"""

import gzip
import json
import logging
import smtplib
from email.message import EmailMessage

import requests

LOG = logging.getLogger("healthreport.deliver")

# ntfy priorities: 5 urgent, 4 high, 3 default.
PRIORITY = {"crit": "5", "warn": "4", "info": "3"}
TAGS = {"crit": "rotating_light", "warn": "warning", "info": "white_check_mark"}


def worst_severity(facts):
    summary = facts["summary"]
    if summary.get("crit"):
        return "crit"
    if summary.get("warn"):
        return "warn"
    return "info"


def send_ntfy(config, facts, title, body):
    if not config.ntfy_url or not config.ntfy_topic:
        return "skipped: no ntfy configuration"

    level = worst_severity(facts)
    marker = "" if facts.get("llm_status") in ("ok", "disabled") else " [no-LLM]"
    headers = {
        "Title": ("%s%s" % (title, marker))[:200],
        "Priority": PRIORITY[level],
        "Tags": "%s,homelab" % TAGS[level],
        "Click": config.grafana_url,
    }
    if config.ntfy_token:
        headers["Authorization"] = "Bearer %s" % config.ntfy_token

    try:
        response = requests.post(
            "%s/%s" % (config.ntfy_url.rstrip("/"), config.ntfy_topic),
            data=body.encode("utf-8"),
            headers=headers,
            timeout=20,
        )
        response.raise_for_status()
        return None
    except requests.exceptions.RequestException as exc:
        LOG.error("ntfy delivery failed: %s", exc)
        return "ntfy: %s" % exc


def send_email(config, facts, subject, body_markdown):
    if not config.email_to or not config.smtp_host:
        return "skipped: no SMTP configuration"

    message = EmailMessage()
    message["Subject"] = subject[:250]
    message["From"] = config.smtp_from
    message["To"] = config.email_to
    message.set_content(body_markdown)

    # Attach the raw facts so the full data is retained even after the state
    # directory rotates.
    payload = json.dumps(facts, indent=2, sort_keys=True, default=str).encode("utf-8")
    if len(payload) > 200 * 1024:
        message.add_attachment(
            gzip.compress(payload),
            maintype="application", subtype="gzip",
            filename="facts-%s.json.gz" % facts["run"]["id"][:10],
        )
    else:
        message.add_attachment(
            payload,
            maintype="application", subtype="json",
            filename="facts-%s.json" % facts["run"]["id"][:10],
        )

    try:
        with smtplib.SMTP(config.smtp_host, config.smtp_port, timeout=60) as smtp:
            smtp.starttls()
            if config.smtp_user:
                smtp.login(config.smtp_user, config.smtp_password)
            smtp.send_message(message)
        return None
    except Exception as exc:
        LOG.error("email delivery failed: %s", exc)
        return "email: %s" % exc


def subject_line(facts):
    summary = facts["summary"]
    if summary.get("crit") or summary.get("warn"):
        state = ", ".join(
            "%d %s" % (summary[level], level)
            for level in ("crit", "warn") if summary.get(level)
        )
    else:
        state = "all clear"
    return "[homelab] daily health — %s — %s" % (state, facts["run"]["id"][:10])
