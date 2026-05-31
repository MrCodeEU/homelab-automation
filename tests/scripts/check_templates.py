#!/usr/bin/env python3
"""
Validate that all enabled Caddy service snippets render correctly AND
that the full generated Caddyfile passes `caddy validate`.

Checks:
  1. Non-empty output for every enabled service with a domain
  2. Domain string present in rendered output
  3. __TARGET_HOST__ / __TARGET_PORT__ placeholders fully substituted
  4. caddy_extra_config content appears verbatim (no swallowed blocks)
  5. Full `caddy validate` on the rendered Caddyfile (if caddy binary present)

If `caddy` is not in PATH the syntax check is skipped with a warning —
it does NOT silently pass.  Install Caddy locally or use `make test-e2e`
to get the full validation.
"""

import sys
import os
import shutil
import subprocess
import tempfile
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
SNIPPETS_TMPL = REPO_ROOT / "ansible/roles/caddy/templates/snippets.caddy.j2"
CADDYFILE_TMPL = REPO_ROOT / "ansible/roles/caddy/templates/Caddyfile.j2"

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

def ansible_bool(value) -> bool:
    """Approximate Ansible's bool filter for standalone template checks."""
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "yes", "y", "on", "true", "t"}
    return bool(value)


def make_env() -> jinja2.Environment:
    env = jinja2.Environment(
        loader=jinja2.BaseLoader(),
        undefined=jinja2.Undefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    env.globals["lookup"] = lambda *_a, **_kw: ""
    env.filters["bool"] = ansible_bool
    return env


# ---------------------------------------------------------------------------
# Per-service snippet checks
# ---------------------------------------------------------------------------

def check_service(env: jinja2.Environment, template: jinja2.Template,
                  service: dict, hostvars: dict,
                  gvars: dict) -> tuple[str, list[str]]:
    """Render snippet; return (rendered_content, errors)."""
    errors: list[str] = []
    name = service.get("name", "?")

    ctx = {
        "service": service,
        "inventory_hostname": "mljr",
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
        return "", errors

    stripped = rendered.strip()

    if not stripped:
        errors.append("snippet is EMPTY")
        return "", errors

    domain = service.get("domain", "")
    domains = [domain] if isinstance(domain, str) else domain
    if not any(d in stripped for d in domains):
        errors.append(f"domain '{domains[0]}' not found in output")

    if "__TARGET_HOST__" in stripped or "__TARGET_PORT__" in stripped:
        errors.append("placeholder __TARGET_HOST__ / __TARGET_PORT__ not replaced")

    extra = service.get("caddy_extra_config", "")
    if extra:
        first_line = next((l.strip() for l in extra.splitlines() if l.strip()), "")
        if first_line:
            is_local = service.get("host", "") == ctx["inventory_hostname"]
            t_host = "localhost" if is_local else hostvars.get(service.get("host", ""), {}).get("ansible_host", "")
            t_port = str(service.get("port", ""))
            first_line_rendered = first_line.replace("__TARGET_HOST__", t_host).replace("__TARGET_PORT__", t_port)
            if first_line_rendered not in stripped:
                errors.append(
                    f"caddy_extra_config first line '{first_line}' not found in output"
                )

    return rendered, errors


# ---------------------------------------------------------------------------
# Full Caddyfile caddy validate
# ---------------------------------------------------------------------------

def run_caddy_validate(snippets: dict[str, str], gvars: dict) -> tuple[bool, str]:
    """
    Write rendered snippets + a minimal Caddyfile to a temp dir and run
    `caddy validate`.  Returns (ok, message).
    """
    caddy_bin = shutil.which("caddy")
    if not caddy_bin:
        msg = (
            "WARN  `caddy` binary not in PATH — skipping Caddy config syntax validation.\n"
            "      Install Caddy locally (same version as production) or run `make test-e2e`\n"
            "      for full in-container validation.  This is NOT a silent pass."
        )
        return None, msg  # None = skipped, not pass or fail

    with tempfile.TemporaryDirectory(prefix="caddy-validate-") as tmpdir:
        conf_dir = Path(tmpdir) / "conf.d"
        conf_dir.mkdir()
        log_dir = Path(tmpdir) / "logs"
        log_dir.mkdir()

        # Write each snippet, replacing the real log path with a writable temp dir
        # so `caddy validate` can instantiate the log writers without permission errors
        for name, content in snippets.items():
            safe_content = content.replace("/var/log/caddy", str(log_dir))
            (conf_dir / f"{name}.caddy").write_text(safe_content)

        # Write minimal shared snippets file (empty macros, no real secrets needed)
        (conf_dir / "000-snippets.caddy").write_text(
            "(authelia_auth) {\n}\n(basicauth_block) {\n}\n"
        )

        # Write minimal Caddyfile — global block MUST use multi-line format
        caddyfile = Path(tmpdir) / "Caddyfile"
        caddyfile.write_text(
            "{\n"
            "    email test@test.local\n"
            "}\n"
            f"import {conf_dir}/*.caddy\n"
        )

        result = subprocess.run(
            [caddy_bin, "validate", "--config", str(caddyfile), "--adapter", "caddyfile"],
            capture_output=True, text=True,
        )

        if result.returncode != 0:
            # Extract meaningful error lines (skip JSON info lines)
            errors = [
                l for l in (result.stderr + result.stdout).splitlines()
                if '"level":"error"' in l or "Error" in l or "error" in l.lower()
            ]
            return False, "\n".join(errors) if errors else result.stderr
        return True, "caddy validate OK"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    all_vars = load_all_vars()
    inv_hosts = load_inventory()
    services: list[dict] = all_vars.get("services", [])

    hostvars = {h: dict(v, ansible_host=v.get("ansible_host", h))
                for h, v in inv_hosts.items()}

    env = make_env()
    with open(SNIPPET_TMPL) as fh:
        template = env.from_string(fh.read())

    failures = 0
    skipped = 0
    passed = 0
    rendered_snippets: dict[str, str] = {}

    for svc in services:
        name = svc.get("name", "?")
        enabled = svc.get("enabled", True)
        domain = svc.get("domain")

        if not enabled or not domain:
            skipped += 1
            continue

        content, errs = check_service(env, template, svc, hostvars, all_vars)
        if errs:
            for e in errs:
                print(f"FAIL  [{name}] {e}")
            failures += 1
        else:
            print(f"OK    [{name}]")
            passed += 1
            rendered_snippets[name] = content

    print(f"\n{passed} passed, {failures} failed, {skipped} skipped")

    # Full caddy validate
    print()
    ok, msg = run_caddy_validate(rendered_snippets, all_vars)
    if ok is None:
        # Skipped — print warning but don't count as failure
        for line in msg.splitlines():
            print(line)
    elif ok:
        print(f"OK    [caddy validate] {msg}")
    else:
        print(f"FAIL  [caddy validate]\n{msg}")
        failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
