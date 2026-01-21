#!/usr/bin/env python3
import os
import sys
import yaml
import time
from uptime_kuma_api import UptimeKumaApi, MonitorType

# Monitor name prefixes for special monitors
PING_PREFIX = "Ping: "
SMTP_PREFIX = "SMTP: "

# SMTP configuration for mailcow
MAILCOW_SMTP_HOST = "mail.mljr.eu"
MAILCOW_SMTP_PORT = 587


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


def sync_service_monitors(api, services, existing_monitors):
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

        print(f"Processing service {name} ({target_url})...")

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
            else:
                print(f"  Skipping {name} (already exists and matches)")
        else:
            print(f"  Creating monitor for {name}...")
            try:
                api.add_monitor(
                    type=MonitorType.HTTP,
                    name=name,
                    url=target_url,
                    interval=60,
                    retryInterval=60
                )
                print(f"  Created {name}")
            except Exception as e:
                print(f"  Failed to create monitor {name}: {e}")


def sync_ping_monitors(api, hosts, existing_monitors):
    """Sync ping monitors for all hosts."""
    for host in hosts:
        hostname = host.get('inventory_hostname')
        ansible_host = host.get('ansible_host')

        if not hostname or not ansible_host:
            continue

        monitor_name = f"{PING_PREFIX}{hostname}"

        print(f"Processing ping monitor {monitor_name} ({ansible_host})...")

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
            else:
                print(f"  Skipping {monitor_name} (already exists and matches)")
        else:
            print(f"  Creating ping monitor for {hostname}...")
            try:
                api.add_monitor(
                    type=MonitorType.PING,
                    name=monitor_name,
                    hostname=ansible_host,
                    maxretries=3,
                    interval=60,
                    retryInterval=60
                )
                print(f"  Created {monitor_name}")
            except Exception as e:
                print(f"  Failed to create ping monitor {monitor_name}: {e}")


def sync_smtp_monitor(api, existing_monitors):
    """Sync SMTP monitor for mailcow."""
    monitor_name = f"{SMTP_PREFIX}{MAILCOW_SMTP_HOST}"

    print(f"Processing SMTP monitor {monitor_name} (port {MAILCOW_SMTP_PORT})...")

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
        else:
            print(f"  Skipping {monitor_name} (already exists and matches)")
    else:
        print(f"  Creating SMTP monitor for {MAILCOW_SMTP_HOST}...")
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
            print(f"  Created {monitor_name}")
        except Exception as e:
            print(f"  Failed to create SMTP monitor: {e}")


def delete_orphaned_monitors(api, expected_names, existing_monitors):
    """Delete monitors that are not in the expected list."""
    for name, monitor in existing_monitors.items():
        if name not in expected_names:
            print(f"Deleting orphaned monitor: {name}")
            try:
                api.delete_monitor(monitor['id'])
                print(f"  Deleted {name}")
            except Exception as e:
                print(f"  Failed to delete monitor {name}: {e}")


def main():
    print("Starting Uptime Kuma provisioning...")

    # Configuration
    url = os.environ.get("KUMA_URL", "http://localhost:3001")
    username = os.environ.get("KUMA_USERNAME")
    password = os.environ.get("KUMA_PASSWORD")
    services_file = sys.argv[1] if len(sys.argv) > 1 else "/opt/kuma/services.yml"

    if not username or not password:
        print("Error: KUMA_USERNAME and KUMA_PASSWORD environment variables must be set.")
        sys.exit(1)

    # Connect to API
    api = UptimeKumaApi(url)

    print(f"Connecting to {url}...")
    try:
        api.login(username, password)
        print("Login successful.")
    except Exception as e:
        print(f"Login failed: {e}")
        print("Ensure Uptime Kuma is set up and credentials are correct.")
        sys.exit(1)

    # Read services.yml
    print(f"Reading {services_file}...")
    if not os.path.exists(services_file):
        print(f"Error: {services_file} not found.")
        sys.exit(1)

    with open(services_file, 'r') as f:
        config = yaml.safe_load(f)

    services = config.get('services', [])
    hosts = config.get('hosts', [])

    print(f"Found {len(services)} services and {len(hosts)} hosts in config.")

    # Get existing monitors
    monitors = api.get_monitors()
    existing_monitors = {m['name']: m for m in monitors}

    print(f"Found {len(existing_monitors)} existing monitors in Kuma.")

    # Build expected monitor names
    expected_names = get_expected_monitor_names(services, hosts)
    print(f"Expecting {len(expected_names)} monitors total.")

    # Sync monitors
    print("\n=== Syncing service monitors ===")
    sync_service_monitors(api, services, existing_monitors)

    print("\n=== Syncing ping monitors ===")
    sync_ping_monitors(api, hosts, existing_monitors)

    print("\n=== Syncing SMTP monitor ===")
    sync_smtp_monitor(api, existing_monitors)

    # Delete orphaned monitors
    print("\n=== Cleaning up orphaned monitors ===")
    delete_orphaned_monitors(api, expected_names, existing_monitors)

    print("\nProvisioning complete.")
    api.disconnect()


if __name__ == "__main__":
    main()
