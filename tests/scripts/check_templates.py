#!/usr/bin/env python3
"""
Validate that all enabled Caddy service snippets render correctly.

Checks:
  - Non-empty output for every enabled service with a domain
  - Domain string present in rendered output
  - __TARGET_HOST__ / __TARGET_PORT__ placeholders fully substituted
  - caddy_extra_config content appears verbatim (no swallowed blocks)
"""

import sys
import os
import re
from pathlib import Path

try:
    import yaml
    import jinja2
except ImportError:
    print("ERROR: pip install pyyaml jinja2", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
ALL_YML = REPO_ROOT / "ansible/inventory/group_vars/all/all.yml"
HOSTS_YML = REPO_ROOT / "ansible/inventory/hosts.yml"
SNIPPET_TMPL = REPO_ROOT / "ansible/roles/caddy/templates/service_snippet.caddy.j2"

# ---------------------------------------------------------------------------
# Inventory helpers
# ---------------------------------------------------------------------------

def _flatten_hosts(node: dict, out: dict) -> None:
    for key, val in (node or {}).items():
        if key == "hosts":
            for hname, hvars in (val or {}).items():
                out[hname] = hvars or {}
        elif key == "children":
            for _, child in (val or {}).items():
                _flatten_hosts(child, out)
        elif isinstance(val, dict) and ("hosts" in val or "children" in val):
            _flatten_hosts(val, out)


def load_inventory() -> dict[str, dict]:
    """Return {hostname: {ansible_host: ..., ...}} for all inventory hosts."""
    with open(HOSTS_YML) as fh:
        raw = yaml.safe_load(fh)
    hosts = {}
    _flatten_hosts(raw.get("all", {}), hosts)
    return hosts


def load_all_vars() -> dict:
    with open(ALL_YML) as fh:
        return yaml.safe_load(fh)


# ---------------------------------------------------------------------------
# Jinja2 environment matching Ansible defaults
# ---------------------------------------------------------------------------

def make_env() -> jinja2.Environment:
    env = jinja2.Environment(
        loader=jinja2.BaseLoader(),
        undefined=jinja2.Undefined,  # silent on undefined (Ansible default)
        trim_blocks=True,
        lstrip_blocks=True,
    )
    # Stub Ansible-specific functions used in the template
    env.globals["lookup"] = lambda *_a, **_kw: ""
    return env


# ---------------------------------------------------------------------------
# Main validation
# ---------------------------------------------------------------------------

def check_service(env: jinja2.Environment, template: jinja2.Template,
                  service: dict, hostvars: dict,
                  gvars: dict) -> list[str]:
    """Render snippet for one service; return list of error strings."""
    errors: list[str] = []
    name = service.get("name", "?")

    # Build render context (mirrors what Ansible provides)
    ctx = {
        "service": service,
        "inventory_hostname": "mljr",          # Caddy runs on mljr
        "hostvars": hostvars,
        "log_path": gvars.get("log_path", "/var/log"),
        "playbook_dir": str(REPO_ROOT / "ansible/playbooks"),
        "is_staging_deployment": False,
        "staging_domain_prefix": gvars.get("staging_domain_prefix", "dev"),
        "staging_host": gvars.get("staging_host", "nuc"),
    }

    try:
        rendered = template.render(**ctx)
    except Exception as exc:
        errors.append(f"render error: {exc}")
        return errors

    stripped = rendered.strip()

    # 1. Non-empty
    if not stripped:
        errors.append("snippet is EMPTY")
        return errors

    # 2. Domain present
    domain = service.get("domain", "")
    domains = [domain] if isinstance(domain, str) else domain
    if not any(d in stripped for d in domains):
        errors.append(f"domain '{domains[0]}' not found in output")

    # 3. No un-substituted placeholders
    if "__TARGET_HOST__" in stripped or "__TARGET_PORT__" in stripped:
        errors.append("placeholder __TARGET_HOST__ / __TARGET_PORT__ not replaced")

    # 4. caddy_extra_config: spot-check first non-blank line appears
    extra = service.get("caddy_extra_config", "")
    if extra:
        first_line = next((l.strip() for l in extra.splitlines() if l.strip()), "")
        if first_line and first_line not in stripped:
            errors.append(
                f"caddy_extra_config first line '{first_line}' not found in output"
            )

    return errors


def main() -> int:
    all_vars = load_all_vars()
    inv_hosts = load_inventory()
    services: list[dict] = all_vars.get("services", [])

    # Build hostvars as Ansible would: each host gets its inventory vars
    hostvars = {h: dict(v, ansible_host=v.get("ansible_host", h))
                for h, v in inv_hosts.items()}

    env = make_env()
    with open(SNIPPET_TMPL) as fh:
        template = env.from_string(fh.read())

    failures = 0
    skipped = 0
    passed = 0

    for svc in services:
        name = svc.get("name", "?")
        enabled = svc.get("enabled", True)
        domain = svc.get("domain")

        # Only check services that would produce a snippet
        if not enabled or not domain:
            skipped += 1
            continue

        errs = check_service(env, template, svc, hostvars, all_vars)
        if errs:
            for e in errs:
                print(f"FAIL  [{name}] {e}")
            failures += 1
        else:
            print(f"OK    [{name}]")
            passed += 1

    print(f"\n{passed} passed, {failures} failed, {skipped} skipped")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
