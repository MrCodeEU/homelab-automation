#!/usr/bin/env python3
"""
Service configuration validator for homelab-automation.

Validates:
- Port uniqueness per host
- Domain uniqueness across all services
- Service name uniqueness
- Host exists in inventory
- Required fields for enabled services
- Docker-compose file exists for managed services
- Staging port convention (+10000)
- YAML syntax
"""

import os
import re
import sys
from pathlib import Path
from collections import defaultdict

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color


def get_repo_root() -> Path:
    """Get the repository root directory."""
    current = Path(__file__).resolve().parent
    while current != current.parent:
        if (current / '.git').exists():
            return current
        current = current.parent
    # Fallback: assume we're in .githooks/
    return Path(__file__).resolve().parent.parent


def load_yaml_file(filepath: Path) -> dict:
    """Load and parse a YAML file."""
    try:
        with open(filepath, 'r') as f:
            return yaml.safe_load(f) or {}
    except yaml.YAMLError as e:
        print(f"{Colors.RED}✗ YAML syntax error in {filepath}:{Colors.NC}")
        print(f"  {e}")
        return None
    except FileNotFoundError:
        print(f"{Colors.RED}✗ File not found: {filepath}{Colors.NC}")
        return None


def extract_hosts_from_inventory(inventory: dict) -> set:
    """Recursively extract all host names from the inventory."""
    hosts = set()
    
    def extract_recursive(data):
        if isinstance(data, dict):
            if 'hosts' in data:
                hosts.update(data['hosts'].keys())
            if 'children' in data:
                for child in data['children'].values():
                    extract_recursive(child)
            for key, value in data.items():
                if key not in ('hosts', 'children'):
                    extract_recursive(value)
    
    extract_recursive(inventory)
    return hosts


def extract_staging_port(docker_compose_path: Path) -> int | None:
    """Extract the host port from a staging docker-compose.yml file."""
    compose = load_yaml_file(docker_compose_path)
    if not compose or 'services' not in compose:
        return None
    
    for service in compose['services'].values():
        ports = service.get('ports', [])
        for port in ports:
            # Parse port mapping like "18080:8080" or "18080:8080/tcp"
            port_str = str(port).split('/')[0]  # Remove protocol
            if ':' in port_str:
                host_port = port_str.split(':')[0]
                try:
                    return int(host_port)
                except ValueError:
                    continue
    return None


def validate_services(repo_root: Path) -> list[str]:
    """Validate all service configurations. Returns list of errors."""
    errors = []
    warnings = []
    
    # Load configuration files
    all_yml_path = repo_root / 'ansible' / 'inventory' / 'group_vars' / 'all' / 'all.yml'
    hosts_yml_path = repo_root / 'ansible' / 'inventory' / 'hosts.yml'
    services_dir = repo_root / 'services'
    
    all_config = load_yaml_file(all_yml_path)
    if all_config is None:
        return [f"Failed to load {all_yml_path}"]
    
    hosts_config = load_yaml_file(hosts_yml_path)
    if hosts_config is None:
        return [f"Failed to load {hosts_yml_path}"]
    
    services = all_config.get('services', [])
    if not services:
        warnings.append("No services defined in all.yml")
    
    # Extract valid hosts from inventory
    valid_hosts = extract_hosts_from_inventory(hosts_config)
    
    # Track for uniqueness checks
    ports_by_host = defaultdict(list)  # host -> [(port, service_name), ...]
    all_domains = []  # [(domain, service_name), ...]
    service_names = []
    
    for service in services:
        name = service.get('name')
        if not name:
            errors.append("Service found without a 'name' field")
            continue
        
        enabled = service.get('enabled', True)
        managed = service.get('managed', True)
        skip_deploy = service.get('skip_deploy', False)
        host = service.get('host')
        port = service.get('port')
        domain = service.get('domain')
        
        # Check service name uniqueness
        if name in service_names:
            errors.append(f"Duplicate service name: '{name}'")
        service_names.append(name)
        
        # Only validate enabled services fully
        if not enabled:
            continue
        
        # Check host exists in inventory
        if host and host not in valid_hosts:
            errors.append(f"Service '{name}': host '{host}' not found in inventory. Valid hosts: {sorted(valid_hosts)}")
        
        # Check required fields
        if not host:
            errors.append(f"Service '{name}': missing required field 'host'")
        
        # Port is required unless it's 0 (no web UI) or managed=false with no port
        if port is None and managed:
            errors.append(f"Service '{name}': missing required field 'port'")
        
        # Track ports per host (only for services with ports > 0)
        if host and port and port > 0:
            ports_by_host[host].append((port, name))
        
        # Track domains
        if domain:
            domains = domain if isinstance(domain, list) else [domain]
            for d in domains:
                all_domains.append((d, name))
        
        # Check docker-compose exists for managed services
        if managed and not skip_deploy:
            compose_path = services_dir / name / 'docker-compose.yml'
            dev_compose_path = services_dir / name / 'dev' / 'docker-compose.yml'
            
            if not compose_path.exists() and not dev_compose_path.exists():
                errors.append(f"Service '{name}': docker-compose.yml not found at {compose_path}")
        
        # Check staging port convention
        dev_compose_path = services_dir / name / 'dev' / 'docker-compose.yml'
        if dev_compose_path.exists() and port and port > 0:
            staging_port = extract_staging_port(dev_compose_path)
            expected_staging_port = port + 10000
            
            if staging_port and staging_port != expected_staging_port:
                warnings.append(
                    f"Service '{name}': staging port {staging_port} doesn't follow +10000 convention "
                    f"(expected {expected_staging_port} based on production port {port})"
                )
    
    # Check port uniqueness per host
    for host, port_list in ports_by_host.items():
        port_counts = defaultdict(list)
        for port, service_name in port_list:
            port_counts[port].append(service_name)
        
        for port, service_names_with_port in port_counts.items():
            if len(service_names_with_port) > 1:
                errors.append(
                    f"Port conflict on host '{host}': port {port} used by multiple services: "
                    f"{', '.join(service_names_with_port)}"
                )
    
    # Check domain uniqueness
    domain_counts = defaultdict(list)
    for domain, service_name in all_domains:
        domain_counts[domain].append(service_name)
    
    for domain, service_names_with_domain in domain_counts.items():
        if len(service_names_with_domain) > 1:
            errors.append(
                f"Domain conflict: '{domain}' used by multiple services: "
                f"{', '.join(service_names_with_domain)}"
            )
    
    # Print warnings
    for warning in warnings:
        print(f"{Colors.YELLOW}⚠ Warning: {warning}{Colors.NC}")
    
    return errors


def main():
    """Main entry point."""
    repo_root = get_repo_root()
    
    print(f"{Colors.BLUE}Validating service configurations...{Colors.NC}")
    
    errors = validate_services(repo_root)
    
    if errors:
        print(f"\n{Colors.RED}Found {len(errors)} error(s):{Colors.NC}")
        for error in errors:
            print(f"  {Colors.RED}✗{Colors.NC} {error}")
        return 1
    
    print(f"{Colors.GREEN}✓ All service validations passed!{Colors.NC}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
