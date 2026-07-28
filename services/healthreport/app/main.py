"""Entry point for the homelab health report.

    python -m app.main --dry-run          # collect, classify, print, send nothing
    python -m app.main --send             # the real run (systemd timer)
    python -m app.main --collect-only --collector victoria

Exit codes: 0 when a report was produced, even with a dead LLM or a failed
collector - those are findings, not crashes. Non-zero only when the framework
itself could not complete.
"""

import argparse
import datetime
import json
import logging
import os
import socket
import sys

from . import deliver, diff, llm, render, severity
from .config import Config
from .model import CollectorResult, Observation
from .collectors import base

# Importing the modules is what populates base.REGISTRY.
from .collectors import github, kuma, loki, ntfy_updates, ssh_facts, victoria  # noqa: F401

LOG = logging.getLogger("healthreport")

DEFAULT_COLLECTORS = [
    "host_metrics", "containers", "logs", "uptime_kuma",
    "ssh_facts", "github", "updates",
]


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Homelab health report")
    parser.add_argument("--send", action="store_true",
                        help="deliver via ntfy and email")
    parser.add_argument("--dry-run", action="store_true",
                        help="collect and render, deliver nothing, do not rotate state")
    parser.add_argument("--collect-only", action="store_true",
                        help="print raw collector output and exit")
    parser.add_argument("--collector", action="append", dest="collectors",
                        help="restrict to this collector (repeatable)")
    parser.add_argument("--diff-only", action="store_true",
                        help="diff two facts files, no network access")
    parser.add_argument("--facts", help="facts file for --diff-only")
    parser.add_argument("--facts-previous", help="previous facts file for --diff-only")
    parser.add_argument("--llm-fixture", help="read the LLM response from this file")
    parser.add_argument("--ollama-url", help="override the Ollama endpoint")
    parser.add_argument("--ntfy-topic", help="override the ntfy topic")
    parser.add_argument("--email-to", help="override the email recipient")
    parser.add_argument("--state-dir", help="override the state directory")
    parser.add_argument("--pretty", action="store_true", help="indent JSON output")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args(argv)


def build_config(args):
    config = Config.from_env()
    if args.ollama_url:
        config.ollama_url = args.ollama_url
    if args.ntfy_topic:
        config.ntfy_topic = args.ntfy_topic
    if args.email_to:
        config.email_to = args.email_to
    if args.state_dir:
        config.state_dir = args.state_dir
    return config


def run_collectors(config, rules, names):
    results = {}
    for name in names:
        fn = base.REGISTRY.get(name)
        if fn is None:
            LOG.warning("unknown collector: %s", name)
            continue
        LOG.info("running collector %s", name)
        results[name] = base.run_collector(name, fn, config, rules)
    return results


def collector_health(results):
    """A collector that did not run is itself a finding.

    Without this, a broken collector looks exactly like a clean bill of health
    - which is the failure mode this whole report exists to prevent.
    """
    observations = []
    for name, result in sorted(results.items()):
        if result.status == "ok":
            continue
        observations.append(Observation(
            id="collector_failed.%s." % name,
            collector="collector_health",
            subject=name,
            kind="collector_failed",
            value=result.status,
            message="collector %s did not complete: %s" % (name, result.error),
            evidence={"status": result.status, "error": result.error},
        ))
    return observations


def assemble(config, rules, results, now):
    observations = []
    for result in results.values():
        observations.extend(result.observations)
    observations.extend(collector_health(results))

    state_dir = config.state_dir
    previous = diff.load_previous(state_dir)
    seen = diff.load_seen(state_dir)

    # First run: nothing is known, so every log signature would look new and
    # the report would be pure noise. Suppress new_only escalation instead.
    known_ids = set(seen.keys())
    if known_ids:
        candidate_new = {obs.id for obs in observations if obs.id not in known_ids}
    else:
        LOG.info("no seen-state yet; suppressing new-only rules for this run")
        candidate_new = set()

    severity.apply(observations, rules, new_ids=candidate_new)

    now_iso = now.isoformat()
    diff_result = diff.compute(observations, previous, seen, now_iso)

    counts = {"crit": 0, "warn": 0, "info": 0}
    for obs in observations:
        counts[obs.severity] = counts.get(obs.severity, 0) + 1

    facts = {
        "schema_version": 1,
        "run": {
            "id": now.strftime("%Y-%m-%dT%H:%M"),
            "started_at": now_iso,
            "host": socket.gethostname(),
        },
        "collectors": {name: result.to_dict() for name, result in results.items()},
        "observations": [obs.to_dict() for obs in observations],
        "diff": diff_result,
        "summary": dict(
            counts,
            collectors_failed=sorted(
                name for name, result in results.items() if result.status != "ok"
            ),
        ),
        "llm_status": "not_run",
    }
    return facts, seen


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    config = build_config(args)
    rules = severity.load_rules(config.rules_path)

    # --- offline diff -------------------------------------------------------
    if args.diff_only:
        if not args.facts:
            LOG.error("--diff-only needs --facts")
            return 2
        with open(args.facts) as fh:
            current = json.load(fh)
        previous = {}
        if args.facts_previous:
            with open(args.facts_previous) as fh:
                previous = json.load(fh)
        observations = [Observation(**_trim(o)) for o in current["observations"]]
        seen = {}
        result = diff.compute(observations, previous, seen,
                              datetime.datetime.now().isoformat())
        json.dump(result, sys.stdout, indent=2 if args.pretty else None)
        sys.stdout.write("\n")
        return 0

    names = args.collectors or DEFAULT_COLLECTORS
    results = run_collectors(config, rules, names)

    # --- raw collector output ----------------------------------------------
    if args.collect_only:
        payload = {
            name: dict(result.to_dict(),
                       observations=[o.to_dict() for o in result.observations])
            for name, result in results.items()
        }
        json.dump(payload, sys.stdout, indent=2 if args.pretty else None, default=str)
        sys.stdout.write("\n")
        return 0

    now = datetime.datetime.now().astimezone()
    facts, seen = assemble(config, rules, results, now)

    # --- narrative ----------------------------------------------------------
    narrative = None
    if args.llm_fixture:
        # Deliberately routed through the same validator as a live response,
        # so a fixture cannot pass something the model could not.
        with open(args.llm_fixture) as fh:
            try:
                narrative = llm.validate(
                    json.load(fh), {o["id"] for o in facts["observations"]})
                facts["llm_status"] = "ok"
            except (ValueError, TypeError) as exc:
                LOG.warning("fixture rejected: %s", exc)
                facts["llm_status"] = "degraded_invalid"
    else:
        narrative, status = llm.summarize(config, facts)
        facts["llm_status"] = status

    body, fallback = render.render(facts, narrative)
    title = render.headline(facts, narrative, fallback)

    # --- delivery -----------------------------------------------------------
    if args.send:
        errors = []
        for error in (
            deliver.send_ntfy(config, facts, title,
                              render.ntfy_body(facts, narrative, fallback)),
            deliver.send_email(config, facts, deliver.subject_line(facts), body),
        ):
            if error and not error.startswith("skipped"):
                errors.append(error)
        facts["delivery_errors"] = errors
        for error in errors:
            LOG.error("delivery problem: %s", error)
    else:
        sys.stdout.write(body)

    # --- state --------------------------------------------------------------
    if args.dry_run:
        path = os.path.join(config.state_dir, "facts-dryrun.json")
        try:
            with open(path, "w") as fh:
                json.dump(facts, fh, indent=2, sort_keys=True, default=str)
            LOG.info("dry run written to %s (state not rotated)", path)
        except OSError as exc:
            LOG.warning("could not write dry-run facts: %s", exc)
    else:
        diff.save(config.state_dir, facts, seen)

    LOG.info("done: %d crit, %d warn, %d new, llm=%s",
             facts["summary"]["crit"], facts["summary"]["warn"],
             len(facts["diff"]["new"]), facts["llm_status"])
    return 0


def _trim(payload):
    """Drop keys the Observation dataclass does not know about."""
    allowed = {
        "id", "collector", "subject", "kind", "message", "severity",
        "value", "unit", "threshold", "evidence", "first_seen",
    }
    return {k: v for k, v in payload.items() if k in allowed}


if __name__ == "__main__":
    sys.exit(main())
