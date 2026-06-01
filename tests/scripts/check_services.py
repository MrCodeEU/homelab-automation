#!/usr/bin/env python3
"""
Test that all enabled production services are reachable.

Skips services that:
  - Are disabled (enabled: false)
  - Have no domain
  - Are in SKIP_NAMES (complex auth, external, or non-HTTP)
  - Match SKIP_PATTERNS

Requires network access to the service domains (VPN / Tailscale).

Usage:
    python3 tests/scripts/check_services.py [--timeout N] [--verbose]
"""

import sys
import os
import argparse
import urllib.request
import urllib.error
import ssl
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import yaml
except ImportError:
    print("ERROR: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
ALL_YML = REPO_ROOT / "ansible/inventory/group_vars/all/all.yml"

# Services to skip entirely (require special auth flows, not HTTP-testable, or
# are complex infrastructure that handles its own probes)
SKIP_NAMES = {
    "mailcow",        # SMTP/IMAP, complex web auth
    "nas",            # NAS UI, requires LAN or specific auth
}

# Services where 401/302/403 is expected (auth wall = service is up)
AUTH_SERVICES = {
    "authelia",       # SSO redirect
    "goaccess",       # auth protected
}

# Accept these status codes as "service is up"
ACCEPTABLE_STATUS = {200, 201, 204, 301, 302, 303, 307, 308, 401, 403}


def get_domains(service: dict) -> list[str]:
    domain = service.get("domain")
    if not domain:
        return []
    return [domain] if isinstance(domain, str) else domain


def check_url(url: str, timeout: int, verbose: bool) -> tuple[str, bool, str]:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-test/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            status = resp.status
            ok = status in ACCEPTABLE_STATUS
            return url, ok, f"HTTP {status}"
    except urllib.error.HTTPError as e:
        ok = e.code in ACCEPTABLE_STATUS
        return url, ok, f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return url, False, f"URLError: {e.reason}"
    except Exception as e:
        return url, False, str(e)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=int, default=10)
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    with open(ALL_YML) as fh:
        all_vars = yaml.safe_load(fh)
    services: list[dict] = all_vars.get("services", [])

    tasks: list[tuple[str, str]] = []   # (service_name, url)

    for svc in services:
        name = svc.get("name", "?")
        if not svc.get("enabled", True):
            continue
        if name in SKIP_NAMES:
            if args.verbose:
                print(f"SKIP  [{name}] (in skip list)")
            continue
        domains = get_domains(svc)
        if not domains:
            continue
        # Test only the first domain to keep it simple
        url = f"https://{domains[0]}"
        tasks.append((name, url))

    if not tasks:
        print("No services to test")
        return 0

    failures = 0
    passed = 0

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check_url, url, args.timeout, args.verbose): (name, url)
                   for name, url in tasks}
        for fut in as_completed(futures):
            svc_name, svc_url = futures[fut]
            url, ok, detail = fut.result()
            if ok:
                if args.verbose:
                    print(f"OK    [{svc_name}] {svc_url} — {detail}")
                else:
                    print(f"OK    [{svc_name}]")
                passed += 1
            else:
                print(f"FAIL  [{svc_name}] {svc_url} — {detail}")
                failures += 1

    print(f"\n{passed} passed, {failures} failed, {len(services) - len(tasks)} skipped")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
