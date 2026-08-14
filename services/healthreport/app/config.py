"""Runtime configuration, read from the environment.

The .env is rendered by ansible/roles/services/templates/env.j2, so every
value here has a matching block there.
"""

import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional


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


def _windows(raw: Optional[str], default: List[str]) -> List[str]:
    """Parse "sun 05:00-08:00,daily 00:00-00:10" into a list.

    An unset variable keeps the defaults; an explicitly empty one
    ("HEALTHREPORT_MAINTENANCE_WINDOWS=") disables suppression entirely, which
    is what you want when checking whether a window is hiding a real problem.
    """
    if raw is None:
        return list(default)
    return [chunk.strip() for chunk in raw.split(",") if chunk.strip()]


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
    # CPU inference on the NAS. 8B at ~10-18 tok/s needs headroom even with
    # thinking disabled; 180s was not enough and every run degraded.
    llm_timeout_s: int = 300

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

    ha_url: str = "http://100.100.10.200:8123"
    ha_token: str = ""

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

    # Scheduled outages, in the container's local time (TZ comes from the
    # services role's env.j2). Traffic-derived findings - 5xx above all - would
    # otherwise report planned maintenance as an incident: the Unraid appdata
    # backup stops thirteen containers for ~2h45 every Sunday and produced
    # ~8,750 5xx, dwarfing a genuine outage. Syntax: "<day> HH:MM-HH:MM" where
    # day is `daily` or a three-letter weekday. Windows may cross midnight.
    maintenance_windows: List[str] = field(default_factory=lambda: [
        # Community Applications docker auto-update stops and restarts every
        # container it manages on nas.
        "daily 00:00-00:10",
        # Unraid appdata backup (plugin cron: Sunday 05:00), ~2h45 wall clock.
        "sun 04:55-08:00",
        # Weekly full deploy (.github/workflows/deploy.yml, Sunday 00:00 UTC),
        # which restarts changed containers. An hour is generous: the deploy
        # itself runs ~15 minutes.
        "sun 02:00-03:00",
    ])
    # A single hour above this many 5xx counts as a bad hour. Sustained badness
    # is the signal; one restart burst is not.
    caddy_5xx_hour_threshold: int = 100

    # Drift detection for nas's backup coverage - basenames (not full paths)
    # of things known to be covered (roles/unraid-backup's unraid_backup_paths
    # `name` values) or deliberately excluded (unraid_backup_excluded). A
    # subfolder appearing in a watched directory that's in neither list is
    # exactly the class of gap that let origami/Fotos/SB sit uncovered for
    # weeks unnoticed - see collectors/ssh_facts.py's backup_drift check.
    backup_known_paths: List[str] = field(default_factory=list)
    backup_excluded_paths: List[str] = field(default_factory=list)

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
            # Defaults to the dataclass value, not a second hard-coded number.
            # These drifted apart: the field said 300 with a comment explaining
            # that 180 was too short, while this line still defaulted to 180, so
            # the deployed budget never changed. On 2026-08-05 that aborted a
            # cold model load at exactly 3m01s and the report shipped with
            # llm_status=unavailable.
            llm_timeout_s=_int("HEALTHREPORT_LLM_TIMEOUT", cls.llm_timeout_s),
            ssh_hosts=_hosts(os.environ.get("HEALTHREPORT_SSH_HOSTS", "")),
            ssh_key_path=os.environ.get("HEALTHREPORT_SSH_KEY", cls.ssh_key_path),
            local_host=os.environ.get("HEALTHREPORT_LOCAL_HOST", cls.local_host),
            github_token=os.environ.get("HEALTHREPORT_GITHUB_TOKEN", ""),
            github_owner=os.environ.get("HEALTHREPORT_GITHUB_OWNER", ""),
            ha_url=os.environ.get("HEALTHREPORT_HA_URL", cls.ha_url),
            ha_token=os.environ.get("HEALTHREPORT_HA_TOKEN", ""),
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
            maintenance_windows=_windows(
                os.environ.get("HEALTHREPORT_MAINTENANCE_WINDOWS"),
                cls.__dataclass_fields__["maintenance_windows"].default_factory()),
            caddy_5xx_hour_threshold=_int("HEALTHREPORT_5XX_HOUR_THRESHOLD", 100),
            backup_known_paths=_windows(os.environ.get("HEALTHREPORT_BACKUP_KNOWN_PATHS"), []),
            backup_excluded_paths=_windows(os.environ.get("HEALTHREPORT_BACKUP_EXCLUDED_PATHS"), []),
        )

    def all_hosts(self) -> List[str]:
        hosts = list(self.ssh_hosts.keys())
        # local_host is normally empty: the facts script lives on the host, not
        # in this container, so every host is reached over SSH including the
        # one the agent runs on.
        if self.local_host and self.local_host not in hosts:
            hosts.append(self.local_host)
        return hosts
