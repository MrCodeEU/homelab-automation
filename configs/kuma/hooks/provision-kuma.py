#!/usr/bin/env python3
import os
import sys
import yaml
import time
from uptime_kuma_api_v2 import UptimeKumaApi, MonitorType

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
    
    # Get existing monitors
    monitors = api.get_monitors()
    existing_monitors = {m['name']: m for m in monitors}
    
    print(f"Found {len(existing_monitors)} existing monitors.")

    # Sync monitors
    for service in services:
        name = service.get('name')
        enabled = service.get('enabled', True)
        domain = service.get('domain')
        
        # Skip if disabled or no domain (unless it has a specific check url, which we don't support in yaml yet)
        if not enabled or not domain:
            continue
        
        # Handle domain as list (use first domain) or string
        if isinstance(domain, list):
            if not domain:  # Empty list
                continue
            domain = domain[0]
            
        # Determine URL
        # If domain starts with http, use it, else assume https
        if domain.startswith("http://") or domain.startswith("https://"):
            target_url = domain
        else:
            target_url = f"https://{domain}"
            
        print(f"Processing {name} ({target_url})...")
        
        if name in existing_monitors:
            # Update? For now, just skip or update URL
            monitor_id = existing_monitors[name]['id']
            current_url = existing_monitors[name]['url']
            
            if current_url != target_url:
                print(f"Updating {name}: {current_url} -> {target_url}")
                api.edit_monitor(
                    id=monitor_id,
                    type=MonitorType.HTTP,
                    url=target_url,
                    name=name
                )
            else:
                print(f"Skipping {name} (already exists and matches)")
        else:
            # Create
            print(f"Creating monitor for {name}...")
            try:
                api.add_monitor(
                    type=MonitorType.HTTP,
                    name=name,
                    url=target_url,
                    interval=60,
                    retryInterval=60
                )
                print(f"Created {name}")
            except Exception as e:
                print(f"Failed to create monitor {name}: {e}")

    print("Provisioning complete.")
    api.disconnect()

if __name__ == "__main__":
    main()
