#!/usr/bin/env python3
"""Generate a small Markdown/Mermaid map of the Ansible inventory and services."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / "docs" / "ansible-map.md"
HOSTS_FILE = REPO_ROOT / "ansible" / "inventory" / "hosts.yml"
ALL_VARS_FILE = REPO_ROOT / "ansible" / "inventory" / "group_vars" / "all" / "all.yml"


def node_id(prefix: str, value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_]", "_", value)
    return f"{prefix}_{slug}"


def mermaid_label(*parts: str) -> str:
    return "<br/>".join(part.replace('"', "'") for part in parts if part)


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def collect_groups(node: dict[str, Any], groups: dict[str, list[str]]) -> None:
    for group_name, group_data in (node.get("children") or {}).items():
        hosts = sorted((group_data.get("hosts") or {}).keys())
        groups[group_name] = hosts
        collect_groups(group_data, groups)


def collect_hosts(node: dict[str, Any], hosts: dict[str, dict[str, Any]]) -> None:
    for name, data in (node.get("hosts") or {}).items():
        hosts[name] = data or {}
    for child in (node.get("children") or {}).values():
        collect_hosts(child, hosts)


def domains_for(service: dict[str, Any]) -> str:
    domain = service.get("domain")
    if not domain:
        return ""
    if isinstance(domain, list):
        return ", ".join(str(item) for item in domain)
    return str(domain)


def render_inventory_graph(groups: dict[str, list[str]], hosts: dict[str, dict[str, Any]]) -> list[str]:
    lines = ["```mermaid", "flowchart LR"]

    for group_name in sorted(groups):
        lines.append(f'  {node_id("group", group_name)}["{mermaid_label(group_name)}"]')

    for host_name, host_data in sorted(hosts.items()):
        label = mermaid_label(host_name, str(host_data.get("tailscale_ip", "")))
        lines.append(f'  {node_id("host", host_name)}["{label}"]')

    for group_name, group_hosts in sorted(groups.items()):
        group_node = node_id("group", group_name)
        for host_name in group_hosts:
            lines.append(f"  {group_node} --> {node_id('host', host_name)}")

    lines.append("```")
    return lines


def render_service_graph(services: list[dict[str, Any]]) -> list[str]:
    lines = ["```mermaid", "flowchart LR"]

    for service in sorted(services, key=lambda item: item["name"]):
        name = service["name"]
        service_node = node_id("svc", name)
        state = "enabled" if service.get("enabled", True) else "disabled"
        managed = "managed" if service.get("managed", True) else "proxy only"
        domain = domains_for(service)
        label = mermaid_label(name, managed, domain)
        lines.append(f'  {service_node}["{label}"]')
        lines.append(f"  {service_node} --> {node_id('host', str(service.get('host', 'unknown')))}")
        if state == "disabled":
            lines.append(f"  class {service_node} disabled")

    lines.append("  classDef disabled fill:#f5f5f5,stroke:#999,color:#777,stroke-dasharray: 4 4;")
    lines.append("```")
    return lines


def render_markdown(hosts: dict[str, dict[str, Any]], groups: dict[str, list[str]], services: list[dict[str, Any]]) -> str:
    enabled_services = [service for service in services if service.get("enabled", True)]
    managed_services = [service for service in enabled_services if service.get("managed", True) and not service.get("skip_deploy", False)]
    proxy_services = [service for service in enabled_services if not service.get("managed", True)]

    lines = [
        "# Ansible Homelab Map",
        "",
        "Generated from `ansible/inventory/hosts.yml` and `ansible/inventory/group_vars/all/all.yml`.",
        "",
        "## Summary",
        "",
        f"- Hosts: {len(hosts)}",
        f"- Inventory groups: {len(groups)}",
        f"- Enabled services: {len(enabled_services)}",
        f"- Managed Compose services: {len(managed_services)}",
        f"- Proxy-only services: {len(proxy_services)}",
        "",
        "## Inventory",
        "",
        *render_inventory_graph(groups, hosts),
        "",
        "## Service Placement",
        "",
        *render_service_graph(enabled_services),
        "",
        "## Services",
        "",
        "| Service | Host | Mode | Domain |",
        "|---------|------|------|--------|",
    ]

    for service in sorted(enabled_services, key=lambda item: item["name"]):
        mode = "dedicated role" if service.get("skip_deploy", False) else ("managed" if service.get("managed", True) else "proxy only")
        lines.append(f"| `{service['name']}` | `{service.get('host', '')}` | {mode} | {domains_for(service)} |")

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    inventory = load_yaml(HOSTS_FILE)
    all_vars = load_yaml(ALL_VARS_FILE)

    hosts: dict[str, dict[str, Any]] = {}
    groups: dict[str, list[str]] = {}
    collect_hosts(inventory.get("all", {}), hosts)
    collect_groups(inventory.get("all", {}), groups)

    output = render_markdown(hosts, groups, all_vars.get("services", []))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(output, encoding="utf-8")
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
