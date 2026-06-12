#!/usr/bin/env python3
"""Build deployment status data and HTML from an Ansible deployment log."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import generate_deploy_page


def load_json(path: Path, default):
    if not path.exists() or path.stat().st_size == 0:
        return default
    with path.open() as fh:
        return json.load(fh)


def parse_failed_services(log_lines: list[str], services: list[dict]) -> dict[str, str]:
    failed_services: dict[str, str] = {}
    current_task_services: list[str] = []

    for line in log_lines:
        task_match = re.search(r"TASK \[(?:[^:]+ : )?(.*?)\]", line)
        if task_match:
            task_name = task_match.group(1).lower()
            current_task_services = []
            for service in services:
                service_name = service.get("name", "").lower()
                if service_name and service_name in task_name:
                    current_task_services.append(service.get("name"))

        if any(marker in line for marker in ("fatal:", "failed:", "FAILED!")):
            error_msg = re.sub(r"\s+", " ", line.strip())[:200]

            for service_name in current_task_services:
                failed_services.setdefault(service_name, error_msg)

            for service in services:
                service_name = service.get("name", "")
                if service_name and service_name.lower() in line.lower():
                    failed_services.setdefault(service_name, error_msg)

    return failed_services


def service_list(services: list[dict]) -> list[dict]:
    result = []
    for service in services:
        if not service.get("enabled", True):
            continue
        domain = service.get("domain")
        if isinstance(domain, list):
            domain = domain[0] if domain else None
        result.append(
            {
                "name": service.get("name"),
                "domain": domain,
                "port": service.get("port"),
                "host": service.get("host"),
                "description": service.get("description", ""),
                "icon": service.get("icon", ""),
                "enabled": True,
                "managed": service.get("managed", True),
            }
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing-json", required=True, type=Path)
    parser.add_argument("--services-json", required=True, type=Path)
    parser.add_argument("--ansible-log", required=True, type=Path)
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--output-html", required=True, type=Path)
    parser.add_argument("--start-time", required=True)
    parser.add_argument("--duration-seconds", required=True, type=int)
    parser.add_argument("--status", required=True)
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--commit-sha", default="")
    parser.add_argument("--commit-message", default="")
    parser.add_argument("--actor", required=True)
    parser.add_argument("--check-mode", action="store_true")
    parser.add_argument("--is-staging", action="store_true")
    parser.add_argument("--limit", default="all")
    parser.add_argument("--tags", default="all")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--ara-artifact", default="")
    parser.add_argument("--targeted-service", default="")
    parser.add_argument("--target-environment", default="")
    args = parser.parse_args()

    services_config = load_json(args.services_json, [])
    existing = load_json(args.existing_json, {"deployments": [], "services": [], "last_updated": ""})

    log_lines = args.ansible_log.read_text(errors="replace").splitlines() if args.ansible_log.exists() else []
    failed_services = parse_failed_services(log_lines, services_config)

    service_results = []
    for service in services_config:
        if not service.get("enabled", True):
            continue
        name = service["name"]
        result = {
            "name": name,
            "host": service.get("host", "unknown"),
            "status": "failed" if name in failed_services else "ok",
        }
        if name in failed_services:
            result["error"] = failed_services[name]
        service_results.append(result)

    summary = {
        "total_services": len(service_results),
        "ok": len([service for service in service_results if service["status"] == "ok"]),
        "failed": len([service for service in service_results if service["status"] == "failed"]),
    }

    commit_short = args.commit_sha[:7]
    deployment = {
        "id": f"{args.start_time}-{commit_short}",
        "timestamp": args.start_time,
        "duration_seconds": args.duration_seconds,
        "status": args.status,
        "trigger": args.trigger,
        "branch": args.branch,
        "commit_sha": commit_short,
        "commit_message": args.commit_message[:100],
        "actor": args.actor,
        "check_mode": args.check_mode,
        "is_staging": args.is_staging,
        "limit": args.limit,
        "tags": args.tags,
        "run_url": args.run_url,
        "ara_artifact": args.ara_artifact,
        "services": service_results,
        "summary": summary,
    }

    if args.targeted_service:
        deployment["targeted_service"] = args.targeted_service
    if args.target_environment:
        deployment["target_environment"] = args.target_environment

    deployments = existing.get("deployments", [])
    deployments.insert(0, deployment)

    data = {
        "deployments": deployments[:500],
        "services": service_list(services_config),
        "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_html.parent.mkdir(parents=True, exist_ok=True)
    with args.output_json.open("w") as fh:
        json.dump(data, fh, indent=2)

    html_content = generate_deploy_page.generate_html(data)
    args.output_html.write_text(html_content)

    print(
        f"Generated deployment status: {deployment['id']} "
        f"({deployment['status']}, services={summary['total_services']}, failed={summary['failed']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
