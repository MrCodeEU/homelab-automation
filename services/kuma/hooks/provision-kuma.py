#!/usr/bin/env python3
"""
Uptime Kuma provisioning script.
Syncs monitors based on services.yml configuration.
"""
import os
import sys
import yaml
from uptime_kuma_api import UptimeKumaApi, MonitorType

# Monitor name prefixes for special monitors
PING_PREFIX = "Ping: "
SMTP_PREFIX = "SMTP: "

# SMTP configuration for mailcow
MAILCOW_SMTP_HOST = "mail.mljr.eu"
MAILCOW_SMTP_PORT = 587


class ProvisioningStats:
    """Track provisioning statistics."""
    def __init__(self):
        self.created = []
        self.updated = []
        self.deleted = []
        self.skipped = 0
        self.failed = []


def get_expected_monitor_names(services, hosts):
    """Build set of all expected monitor names (services + ping + smtp)."""
    expected = set()

    # Service monitors (HTTP)
    for service in services:
        name = service.get('name')
        enabled = service.get('enabled', True)
        domain = service.get('domain')

        if enabled and domain:
            expected.add(name)

    # Ping monitors for hosts
    for host in hosts:
        hostname = host.get('inventory_hostname')
        if hostname:
            expected.add(f"{PING_PREFIX}{hostname}")

    # SMTP monitor for mailcow
    expected.add(f"{SMTP_PREFIX}{MAILCOW_SMTP_HOST}")

    return expected


def sync_service_monitors(api, services, existing_monitors, stats):
    """Sync HTTP monitors for services."""
    for service in services:
        name = service.get('name')
        enabled = service.get('enabled', True)
        domain = service.get('domain')

        # Skip if disabled or no domain
        if not enabled or not domain:
            continue

        # Handle domain as list (use first domain) or string
        if isinstance(domain, list):
            if not domain:
                continue
            domain = domain[0]

        # Determine URL
        if domain.startswith("http://") or domain.startswith("https://"):
            target_url = domain
        else:
            target_url = f"https://{domain}"

        if name in existing_monitors:
            monitor_id = existing_monitors[name]['id']
            current_url = existing_monitors[name].get('url', '')

            if current_url != target_url:
                print(f"  Updating {name}: {current_url} -> {target_url}")
                api.edit_monitor(
                    id=monitor_id,
                    type=MonitorType.HTTP,
                    url=target_url,
                    name=name
                )
                stats.updated.append(name)
            else:
                stats.skipped += 1
        else:
            print(f"  Creating {name} ({target_url})")
            try:
                api.add_monitor(
                    type=MonitorType.HTTP,
                    name=name,
                    url=target_url,
                    interval=60,
                    retryInterval=60
                )
                stats.created.append(name)
            except Exception as e:
                print(f"  Failed to create {name}: {e}")
                stats.failed.append(name)


def sync_ping_monitors(api, hosts, existing_monitors, stats):
    """Sync ping monitors for all hosts."""
    for host in hosts:
        hostname = host.get('inventory_hostname')
        ansible_host = host.get('ansible_host')

        if not hostname or not ansible_host:
            continue

        monitor_name = f"{PING_PREFIX}{hostname}"

        if monitor_name in existing_monitors:
            monitor_id = existing_monitors[monitor_name]['id']
            current_hostname = existing_monitors[monitor_name].get('hostname', '')
            current_retries = existing_monitors[monitor_name].get('maxretries', 0)

            # Update if hostname or retries changed
            if current_hostname != ansible_host or current_retries != 3:
                print(f"  Updating {monitor_name}: hostname={ansible_host}, maxretries=3")
                api.edit_monitor(
                    id=monitor_id,
                    type=MonitorType.PING,
                    name=monitor_name,
                    hostname=ansible_host,
                    maxretries=3,
                    interval=60,
                    retryInterval=60
                )
                stats.updated.append(monitor_name)
            else:
                stats.skipped += 1
        else:
            print(f"  Creating {monitor_name} ({ansible_host})")
            try:
                api.add_monitor(
                    type=MonitorType.PING,
                    name=monitor_name,
                    hostname=ansible_host,
                    maxretries=3,
                    interval=60,
                    retryInterval=60
                )
                stats.created.append(monitor_name)
            except Exception as e:
                print(f"  Failed to create {monitor_name}: {e}")
                stats.failed.append(monitor_name)


def sync_smtp_monitor(api, existing_monitors, stats):
    """Sync SMTP monitor for mailcow."""
    monitor_name = f"{SMTP_PREFIX}{MAILCOW_SMTP_HOST}"

    if monitor_name in existing_monitors:
        monitor_id = existing_monitors[monitor_name]['id']
        current_hostname = existing_monitors[monitor_name].get('hostname', '')
        current_port = existing_monitors[monitor_name].get('port', 0)

        # Update if hostname or port changed
        if current_hostname != MAILCOW_SMTP_HOST or current_port != MAILCOW_SMTP_PORT:
            print(f"  Updating {monitor_name}")
            api.edit_monitor(
                id=monitor_id,
                type=MonitorType.SMTP,
                name=monitor_name,
                hostname=MAILCOW_SMTP_HOST,
                port=MAILCOW_SMTP_PORT,
                smtpSecurity="STARTTLS",
                interval=60,
                retryInterval=60
            )
            stats.updated.append(monitor_name)
        else:
            stats.skipped += 1
    else:
        print(f"  Creating {monitor_name} (port {MAILCOW_SMTP_PORT})")
        try:
            api.add_monitor(
                type=MonitorType.SMTP,
                name=monitor_name,
                hostname=MAILCOW_SMTP_HOST,
                port=MAILCOW_SMTP_PORT,
                smtpSecurity="STARTTLS",
                interval=60,
                retryInterval=60
            )
            stats.created.append(monitor_name)
        except Exception as e:
            print(f"  Failed to create SMTP monitor: {e}")
            stats.failed.append(monitor_name)


def delete_orphaned_monitors(api, expected_names, existing_monitors, stats):
    """Delete monitors that are not in the expected list."""
    for name, monitor in existing_monitors.items():
        if name not in expected_names:
            print(f"  Deleting orphaned monitor: {name}")
            try:
                api.delete_monitor(monitor['id'])
                stats.deleted.append(name)
            except Exception as e:
                print(f"  Failed to delete {name}: {e}")
                stats.failed.append(f"delete:{name}")


def main():
    print("Uptime Kuma provisioning started")

    # Configuration
    url = os.environ.get("KUMA_URL", "http://localhost:3001")
    username = os.environ.get("KUMA_USERNAME")
    password = os.environ.get("KUMA_PASSWORD")
    services_file = sys.argv[1] if len(sys.argv) > 1 else "/opt/kuma/services.yml"

    if not username or not password:
        print("Error: KUMA_USERNAME and KUMA_PASSWORD must be set")
        sys.exit(1)

    # Connect to API
    print(f"Connecting to Uptime Kuma at {url}")
    api = UptimeKumaApi(url)

    try:
        print(f"Attempting login with username: {username}")
        api.login(username, password)
        print("Login successful")
    except Exception as e:
        print(f"Login failed: {e}")
        print("This may happen if:")
        print("  - First-time setup: Please complete initial setup via web UI first")
        print("  - Wrong credentials: Check KUMA_USERNAME and KUMA_PASSWORD in secrets")
        print("  - API not ready: Kuma may still be starting up")
        sys.exit(1)

    # Read services.yml
    if not os.path.exists(services_file):
        print(f"Error: {services_file} not found")
        print(f"Expected path: {os.path.abspath(services_file)}")
        sys.exit(1)

    print(f"Reading services from {services_file}")
    with open(services_file, 'r') as f:
        config = yaml.safe_load(f)

    services = config.get('services', [])
    hosts = config.get('hosts', [])

    # Get existing monitors
    monitors = api.get_monitors()
    existing_monitors = {m['name']: m for m in monitors}

    # Build expected monitor names
    expected_names = get_expected_monitor_names(services, hosts)

    print(f"Config: {len(services)} services, {len(hosts)} hosts | Kuma: {len(existing_monitors)} monitors | Expected: {len(expected_names)}")

    # Track statistics
    stats = ProvisioningStats()

    # Sync monitors (only prints when making changes)
    sync_service_monitors(api, services, existing_monitors, stats)
    sync_ping_monitors(api, hosts, existing_monitors, stats)
    sync_smtp_monitor(api, existing_monitors, stats)
    delete_orphaned_monitors(api, expected_names, existing_monitors, stats)

    # Print summary
    summary_parts = []
    if stats.created:
        summary_parts.append(f"created {len(stats.created)}")
    if stats.updated:
        summary_parts.append(f"updated {len(stats.updated)}")
    if stats.deleted:
        summary_parts.append(f"deleted {len(stats.deleted)}")
    if stats.skipped:
        summary_parts.append(f"unchanged {stats.skipped}")
    if stats.failed:
        summary_parts.append(f"failed {len(stats.failed)}")

    if summary_parts:
        print(f"Summary: {', '.join(summary_parts)}")
    else:
        print("Summary: no changes")

    api.disconnect()

    # Exit with error if any failures
    if stats.failed:
        print(f"\nFailed operations: {stats.failed}")
        print("Check the errors above for details")
        sys.exit(1)

    print("Provisioning completed successfully")


if __name__ == "__main__":
    main()
