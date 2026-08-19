"""Facts fetched over the forced-command SSH endpoint.

Mirrors services/healthreport/app/collectors/ssh_facts.py's fetch() almost
exactly - same key, same forced-command target, same host set (minus
ugreen, which is a destination here, not a catalog source). Kept as a
separate small module rather than importing healthreport's collector
directly, so the two services' deploy/release cycles stay decoupled.
"""

import json
import logging
import subprocess

LOG = logging.getLogger("backup-dashboard")

SSH_OPTIONS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "IdentitiesOnly=yes",
]


def fetch(config, host, address):
    args = (["ssh"] + SSH_OPTIONS
            + ["-i", config.ssh_key_path, "root@%s" % address, config.local_facts_bin])
    proc = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, shell=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "%s: exit %d: %s" % (host, proc.returncode, proc.stderr.decode("utf-8", "replace")[:300])
        )
    return json.loads(proc.stdout.decode("utf-8", "replace"))


def fetch_all(config):
    """Best-effort per host: one unreachable host must not blank the page."""
    payloads = {}
    errors = {}
    for host, address in config.ssh_hosts.items():
        try:
            payloads[host] = fetch(config, host, address)
        except Exception as exc:  # noqa: BLE001 - reported, not fatal
            LOG.warning("facts fetch failed for %s: %s", host, exc)
            errors[host] = str(exc)
    return payloads, errors
