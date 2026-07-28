"""GitHub repository health across the whole account.

Covers every repo owned by the configured user, not just this one: workflow
run conclusions, open Dependabot alerts and open code scanning alerts.

Needs a fine-grained PAT with Metadata/Actions/Dependabot alerts/Code scanning
alerts read access. Repos with a feature disabled answer 403/404; that is
"unavailable", not an error, and must not colour the report.
"""

import datetime

import requests

from ..model import CollectorResult, Observation
from .base import collector

API = "https://api.github.com"
PAGE = 100


def _session(config):
    session = requests.Session()
    session.headers.update({
        "Authorization": "Bearer %s" % config.github_token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "homelab-healthreport",
    })
    return session


def _get(session, url, **params):
    response = session.get(url, params=params or None, timeout=30)
    if response.status_code in (403, 404):
        # Feature disabled for this repo, or no access. Not a failure.
        return None, response
    response.raise_for_status()
    return response.json(), response


@collector("github")
def collect(config, rules):
    result = CollectorResult(name="github")
    obs = result.observations

    if not config.github_token:
        result.status = "unavailable"
        result.error = "no GitHub token configured (secrets.github_readonly.token)"
        return result

    session = _session(config)
    data = {"repos": [], "unavailable": []}

    # The token warns about its own expiry, so the report never dies quietly
    # when the credential lapses.
    probe = session.get(API + "/user", timeout=30)
    probe.raise_for_status()
    expiry = probe.headers.get("github-authentication-token-expiration")
    if expiry:
        try:
            expires_at = datetime.datetime.strptime(expiry[:10], "%Y-%m-%d")
            days = (expires_at - datetime.datetime.utcnow()).days
            data["token_expires_in_days"] = days
            obs.append(Observation(
                id="github_token_expiry..",
                collector="github",
                subject="github",
                kind="github_token_expiry",
                value=days,
                unit="days",
                message="GitHub token expires in %d days" % days,
                evidence={"expires_at": expiry},
            ))
        except ValueError:
            pass

    owner = config.github_owner or probe.json().get("login", "")

    repos = []
    page = 1
    while True:
        batch, _ = _get(session, API + "/user/repos",
                        affiliation="owner", per_page=PAGE, page=page)
        if not batch:
            break
        repos.extend(batch)
        if len(batch) < PAGE:
            break
        page += 1

    since = (datetime.datetime.utcnow()
             - datetime.timedelta(hours=config.lookback_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")

    for repo in repos:
        name = repo.get("name")
        full = repo.get("full_name")
        default_branch = repo.get("default_branch", "main")
        if repo.get("archived"):
            continue
        entry = {"repo": full, "default_branch": default_branch}

        runs, _ = _get(session, "%s/repos/%s/actions/runs" % (API, full),
                       created=">=%s" % since[:10], per_page=50)
        if runs is None:
            data["unavailable"].append("%s:actions" % full)
        else:
            failures = [
                run for run in runs.get("workflow_runs", [])
                if run.get("conclusion") in ("failure", "timed_out", "startup_failure")
            ]
            entry["failed_runs"] = len(failures)
            # One observation per workflow, not per run: ten failures of the
            # same workflow is one problem, not ten.
            seen_workflows = {}
            for run in failures:
                key = (run.get("name") or "workflow", run.get("head_branch") or "?")
                seen_workflows.setdefault(key, run)
            for (workflow, branch), run in seen_workflows.items():
                on_default = branch == default_branch
                kind = "workflow_failed_default_branch" if on_default else "workflow_failed"
                obs.append(Observation(
                    id="%s.%s.%s" % (kind, name, workflow),
                    collector="github",
                    subject=name,
                    kind=kind,
                    value=run.get("conclusion"),
                    message="%s: workflow %s failed on %s" % (full, workflow, branch),
                    evidence={"url": run.get("html_url"), "branch": branch},
                ))

        alerts, _ = _get(session, "%s/repos/%s/dependabot/alerts" % (API, full),
                         state="open", per_page=PAGE)
        if alerts is None:
            data["unavailable"].append("%s:dependabot" % full)
        else:
            entry["dependabot_open"] = len(alerts)
            for alert in alerts:
                advisory = alert.get("security_advisory") or {}
                severity = (advisory.get("severity") or "unknown").lower()
                package = ((alert.get("dependency") or {}).get("package") or {}).get("name", "?")
                obs.append(Observation(
                    id="dependabot_alert.%s.%s" % (name, alert.get("number")),
                    collector="github",
                    subject=name,
                    kind="dependabot_alert",
                    value=severity,
                    message="%s: %s Dependabot alert in %s - %s"
                            % (full, severity, package, (advisory.get("summary") or "")[:120]),
                    evidence={"url": alert.get("html_url"), "package": package},
                ))

        scanning, _ = _get(session, "%s/repos/%s/code-scanning/alerts" % (API, full),
                           state="open", per_page=PAGE)
        if scanning is None:
            data["unavailable"].append("%s:code-scanning" % full)
        else:
            entry["code_scanning_open"] = len(scanning)
            for alert in scanning:
                rule = alert.get("rule") or {}
                severity = (rule.get("security_severity_level")
                            or rule.get("severity") or "unknown").lower()
                obs.append(Observation(
                    id="code_scanning_alert.%s.%s" % (name, alert.get("number")),
                    collector="github",
                    subject=name,
                    kind="code_scanning_alert",
                    value=severity,
                    message="%s: %s code scanning alert - %s"
                            % (full, severity, (rule.get("description") or rule.get("id") or "")[:120]),
                    evidence={"url": alert.get("html_url")},
                ))

        data["repos"].append(entry)

    data["repo_count"] = len(data["repos"])
    data["owner"] = owner
    result.data = data
    return result
