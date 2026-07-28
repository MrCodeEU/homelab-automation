"""Runtime configuration, read from the environment.

The .env is rendered by ansible/roles/services/templates/env.j2, so every
value here has a matching block there.
"""

import os
from dataclasses import dataclass, field
from typing import Dict, List


def _bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip())
    except ValueError:
        return default


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
    rules_path: str = "/app/rules.yml"

    victoria_url: str = "http://127.0.0.1:19090"
    loki_url: str = "http://127.0.0.1:3100"
    kuma_url: str = "http://127.0.0.1:3001"
    kuma_api_key: str = ""

    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "qwen3:8b"
    llm_enabled: bool = False
    llm_timeout_s: int = 180

    # Hosts reachable through the forced-command SSH endpoint. The local host
    # runs the script directly instead of dialling itself over SSH.
    ssh_hosts: Dict[str, str] = field(default_factory=dict)
    ssh_key_path: str = "/ssh/id_ed25519"
    # Empty by default: see all_hosts(). Set only if the facts script is
    # somehow available inside the container.
    local_host: str = ""
    local_facts_bin: str = "/usr/local/bin/homelab-facts"

    github_token: str = ""
    github_owner: str = ""

    ntfy_url: str = "https://ntfy.mljr.eu"
    ntfy_topic: str = "homelab-health"
    ntfy_token: str = ""

    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = "notifications@mljr.eu"
    email_to: str = ""

    grafana_url: str = "https://monitor.mljr.eu"
    lookback_hours: int = 24

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            state_dir=os.environ.get("HEALTHREPORT_STATE_DIR", "/state"),
            rules_path=os.environ.get("HEALTHREPORT_RULES", "/app/rules.yml"),
            victoria_url=os.environ.get("HEALTHREPORT_VM_URL", cls.victoria_url),
            loki_url=os.environ.get("HEALTHREPORT_LOKI_URL", cls.loki_url),
            kuma_url=os.environ.get("HEALTHREPORT_KUMA_URL", cls.kuma_url),
            kuma_api_key=os.environ.get("HEALTHREPORT_KUMA_API_KEY", ""),
            ollama_url=os.environ.get("HEALTHREPORT_OLLAMA_URL", cls.ollama_url),
            ollama_model=os.environ.get("HEALTHREPORT_MODEL", cls.ollama_model),
            llm_enabled=_bool("HEALTHREPORT_LLM_ENABLED", False),
            llm_timeout_s=_int("HEALTHREPORT_LLM_TIMEOUT", 180),
            ssh_hosts=_hosts(os.environ.get("HEALTHREPORT_SSH_HOSTS", "")),
            ssh_key_path=os.environ.get("HEALTHREPORT_SSH_KEY", cls.ssh_key_path),
            local_host=os.environ.get("HEALTHREPORT_LOCAL_HOST", cls.local_host),
            github_token=os.environ.get("HEALTHREPORT_GITHUB_TOKEN", ""),
            github_owner=os.environ.get("HEALTHREPORT_GITHUB_OWNER", ""),
            ntfy_url=os.environ.get("HEALTHREPORT_NTFY_URL", cls.ntfy_url),
            ntfy_topic=os.environ.get("HEALTHREPORT_NTFY_TOPIC", cls.ntfy_topic),
            ntfy_token=os.environ.get("HEALTHREPORT_NTFY_TOKEN", ""),
            smtp_host=os.environ.get("HEALTHREPORT_SMTP_HOST", ""),
            smtp_port=_int("HEALTHREPORT_SMTP_PORT", 587),
            smtp_user=os.environ.get("HEALTHREPORT_SMTP_USER", ""),
            smtp_password=os.environ.get("HEALTHREPORT_SMTP_PASSWORD", ""),
            smtp_from=os.environ.get("HEALTHREPORT_SMTP_FROM", cls.smtp_from),
            email_to=os.environ.get("HEALTHREPORT_EMAIL_TO", ""),
            grafana_url=os.environ.get("HEALTHREPORT_GRAFANA_URL", cls.grafana_url),
            lookback_hours=_int("HEALTHREPORT_LOOKBACK_HOURS", 24),
        )

    def all_hosts(self) -> List[str]:
        hosts = list(self.ssh_hosts.keys())
        # local_host is normally empty: the facts script lives on the host, not
        # in this container, so every host is reached over SSH including the
        # one the agent runs on.
        if self.local_host and self.local_host not in hosts:
            hosts.append(self.local_host)
        return hosts
