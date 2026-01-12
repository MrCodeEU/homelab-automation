# Homelab Automation - Ansible

This directory contains the Ansible configuration for managing the `mljr.eu` homelab infrastructure. It automates the deployment of services, security configurations, backups, and reverse proxy setup.

## Project Overview

*   **Type:** Ansible Automation Project
*   **Target OS:** Primarily Rocky Linux (managed hosts), with support for Debian/Ubuntu.
*   **Main Domain:** `mljr.eu`
*   **Key Components:**
    *   **Caddy:** Reverse proxy handling SSL and routing.
    *   **Docker:** Container orchestration for most services.
    *   **Glance:** Main dashboard.
    *   **Mailcow:** Mail server solution.
    *   **Rclone:** Backup synchronization to pCloud.

## Directory Structure

*   **`inventory/`**: Defines hosts and groups.
    *   `hosts.yml`: Main inventory file.
    *   `group_vars/all/all.yml`: Global configuration, including the **Service Catalog**.
    *   `group_vars/all/secrets.yml`: Encrypted secrets (ensure `ansible-vault` is used).
*   **`playbooks/`**: Entry point playbooks.
    *   `site.yml`: Main playbook to deploy everything.
*   **`roles/`**: Reusable Ansible roles.
    *   `base`: System packages, Docker installation.
    *   `caddy`: Caddy reverse proxy configuration.
    *   `services`: Generic role to deploy Docker Compose services defined in `all.yml`.
    *   `backup`: Backup scripts and Rclone configuration.
    *   `fail2ban`: Security configuration.
    *   `glance`: Deploys the Glance dashboard.
    *   `mailcow`: Deploys Mailcow (dockerized).
*   **`ansible.cfg`**: Ansible runtime configuration (performance, paths, privilege escalation).

## Key Concepts

### Service Catalog (`group_vars/all/all.yml`)
Services are defined in the `services` list. Each entry controls:
*   `enabled`: Toggle deployment.
*   `managed`: If `false`, Ansible only configures the Caddy proxy (for external hosts like Unraid/Pi).
*   `staging`: If `true`, deploys a second instance on `port + 10000` with `dev.` subdomain prefix.
*   `caddy_auth`: Enables Basic Auth if set to `"basicauth"`.

### Staging Environment
Global variables `staging_port_offset` (10000) and `staging_domain_prefix` ("dev") control the staging environment. Services marked with `staging: true` will be deployed twice: once for production and once for staging.

### Hosts
*   **Managed (`rocky`)**: Full Ansible control (Base, Docker, Services, Security). Example: `mljr`.
*   **Proxy Only**: Ansible only configures Caddy to reverse proxy to these hosts. Examples: `pi` (Home Assistant), `nas` (Unraid services).
*   **Unraid**: Limited management.

## Usage

### Prerequisites
*   Ansible installed.
*   SSH access to target hosts (configured in `~/.ssh/config` or via `ansible_host`).
*   `ansible-galaxy` collections installed:
    ```bash
    ansible-galaxy install -r requirements.yml
    ```

### Common Commands

**Deploy Everything:**
```bash
ansible-playbook playbooks/site.yml
```

**Deploy Specific Tag (e.g., only Caddy config):**
```bash
ansible-playbook playbooks/site.yml --tags caddy
```

**Limit to Specific Host:**
```bash
ansible-playbook playbooks/site.yml --limit mljr
```

**Tags Available:**
*   `base`: System setup & Docker.
*   `services`: Docker containers.
*   `caddy`: Reverse proxy.
*   `backup`: Backup scripts.
*   `security`: Fail2ban.
*   `glance`: Dashboard.
*   `mailcow`: Mail server.

## Development Conventions

*   **Idempotency:** Ensure all tasks can be run multiple times without side effects.
*   **Variables:** Prefer defining variables in `group_vars/all/all.yml` rather than hardcoding in tasks.
*   **Secrets:** NEVER commit secrets in plain text. Use Ansible Vault for `secrets.yml`.
*   **Templates:** Use Jinja2 (`.j2`) templates for configuration files.
