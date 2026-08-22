"""Runtime configuration, read from the environment.

The .env is rendered by ansible/roles/services/templates/env.j2, mirroring
services/healthreport/app/config.py's convention - every value here has a
matching env.j2 block.
"""

import os
from dataclasses import dataclass, field
from typing import Dict


def _hosts(raw: str) -> Dict[str, str]:
    """Parse "mljr=100.100.20.1,nas=100.100.10.2" into a mapping."""
    out = {}
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        name, _, addr = chunk.partition("=")
        out[name.strip()] = addr.strip()
    return out


@dataclass
class Config:
    state_dir: str = "/state"
    catalog_path: str = "/catalog/backup_catalog.json"
    output_path: str = "/output/index.html"
    template_path: str = "/app/templates/index.html.j2"

    victoria_url: str = "http://127.0.0.1:19090"

    # Hosts reachable through the same forced-command SSH endpoint healthreport
    # uses (see ansible/roles/host-facts-endpoint) - this collector reuses
    # healthreport's own SSH key rather than minting a new one, so it needs no
    # new authorization on any host.
    ssh_hosts: Dict[str, str] = field(default_factory=dict)
    ssh_key_path: str = "/ssh/id_ed25519"
    local_facts_bin: str = "/usr/local/bin/homelab-facts"

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            state_dir=os.environ.get("BACKUP_DASHBOARD_STATE_DIR", cls.state_dir),
            catalog_path=os.environ.get("BACKUP_DASHBOARD_CATALOG_PATH", cls.catalog_path),
            output_path=os.environ.get("BACKUP_DASHBOARD_OUTPUT_PATH", cls.output_path),
            template_path=os.environ.get("BACKUP_DASHBOARD_TEMPLATE_PATH", cls.template_path),
            victoria_url=os.environ.get("BACKUP_DASHBOARD_VICTORIA_URL", cls.victoria_url),
            ssh_hosts=_hosts(os.environ.get("BACKUP_DASHBOARD_SSH_HOSTS", "")),
            ssh_key_path=os.environ.get("BACKUP_DASHBOARD_SSH_KEY_PATH", cls.ssh_key_path),
            local_facts_bin=os.environ.get("BACKUP_DASHBOARD_LOCAL_FACTS_BIN", cls.local_facts_bin),
        )
