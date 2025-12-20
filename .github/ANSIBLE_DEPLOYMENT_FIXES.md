# Ansible Deployment Workflow Fixes

## Date: 2025-12-20

## Overview
This document details the fixes applied to resolve issues in the Ansible deployment workflow that were causing failures in the GitHub Actions CI/CD pipeline.

## Issues Identified

### 1. Caddy Role - Conflicting Web Servers Task Failure
**Problem:** The task "Stop conflicting web servers" was attempting to stop `httpd`, `nginx`, and `apache2` services, but these services didn't exist on the target hosts, causing the task to fail.

**Error Message:**
```
Could not find the requested service httpd: host
Could not find the requested service nginx: host
Could not find the requested service apache2: host
```

**Root Cause:** The task was trying to manage services without first checking if they exist on the system.

**Solution:**
- Added `service_facts` module to gather information about available services
- Added conditional `when` clause to only attempt stopping services if they exist
- Kept `ignore_errors: yes` as a fallback

**Changes in `ansible/roles/caddy/tasks/main.yml`:**
```yaml
- name: Check for conflicting web servers
  service_facts:

- name: Stop conflicting web servers
  service:
    name: "{{ item }}"
    state: stopped
    enabled: no
  loop:
    - httpd
    - nginx
    - apache2
  when: "item + '.service' in services or item in services"
  ignore_errors: yes
```

### 2. Services Role - Missing Glance docker-compose.yml
**Problem:** The services role was trying to copy a docker-compose.yml file for Glance, but Glance is managed by a dedicated Ansible role (glance role), not the generic services role.

**Error Message:**
```
Could not find or access '/home/runner/work/homelab-automation/homelab-automation/ansible/playbooks/../../configs/glance/docker-compose.yml' on the Ansible Controller.
```

**Root Cause:** Glance doesn't have a docker-compose.yml file in the configs directory because it's deployed directly as a Docker container by the glance role. The services role shouldn't try to manage it.

**Solution:**
- Added condition `item.name not in ['glance']` to skip Glance in all services role tasks
- This prevents the services role from attempting to manage Glance

**Changes in `ansible/roles/services/tasks/main.yml`:**
```yaml
when:
  - item.enabled | default(true)
  - item.managed | default(true)
  - inventory_hostname == item.host
  - item.name not in ['glance']  # Skip services managed by dedicated roles
```

### 3. Services Role - Recursive Variable Loop
**Problem:** Variables in the `vars` section were shadowing the extra vars passed from the workflow, causing infinite recursion.

**Error Message:**
```
Recursive loop detected in template: maximum recursion depth exceeded
```

**Root Cause:** The task was defining variables with the same names as the extra vars being passed in:
```yaml
vars:
  nightscout_api_secret: "{{ nightscout_api_secret | default('') }}"
```
This creates a circular reference where `nightscout_api_secret` references itself.

**Solution:**
- Renamed all template variables to have a `_var` suffix to avoid shadowing
- Updated the Jinja2 template to use the renamed variables

**Changes:**

`ansible/roles/services/tasks/main.yml`:
```yaml
vars:
  # Map secrets to template variables (renamed to avoid shadowing)
  nightscout_api_secret_var: "{{ nightscout_api_secret | default('') }}"
  link_up_username_var: "{{ link_up_username | default('') }}"
  link_up_password_var: "{{ link_up_password | default('') }}"
  nightscout_api_token_var: "{{ nightscout_api_token | default('') }}"
  nightscout_domain_var: "{{ nightscout_domain | default('') }}"
  bichon_encrypt_password_var: "{{ bichon_encrypt_password | default('') }}"
```

`ansible/roles/services/templates/env.j2`:
```jinja
API_SECRET={{ nightscout_api_secret_var }}
LINK_UP_USERNAME={{ link_up_username_var }}
LINK_UP_PASSWORD={{ link_up_password_var }}
API_TOKEN={{ nightscout_api_token_var }}
NIGHTSCOUT_DOMAIN={{ nightscout_domain_var }}
BICHON_ENCRYPT_PASSWORD={{ bichon_encrypt_password_var }}
```

## Testing

### Syntax Check
```bash
cd ansible
ansible-playbook --syntax-check playbooks/site.yml
```
Result: ✅ Passed

### YAML Linting
All critical errors (trailing spaces) have been fixed. Only minor warnings remain (line length).

## Workflow Execution Flow

The fixed workflow now executes as follows:

1. **Checkout** - Repository code is checked out
2. **Tailscale Setup** - VPN connection established
3. **Ansible Installation** - Ansible is installed (with caching)
4. **Playbook Execution**:
   - **Base Setup** (common, docker roles) - Runs on rocky:debian hosts
   - **Caddy Setup** (caddy role) - Runs on rocky hosts
     - ✅ Checks for conflicting web servers before attempting to stop them
   - **Glance Setup** (glance role) - Runs on mljr host only
     - Deploys Glance as a Docker container
   - **Services Setup** (services role) - Runs on rocky:debian hosts
     - ✅ Skips Glance (managed by dedicated role)
     - ✅ Creates .env files with properly mapped variables
     - Deploys other services via docker-compose

## Files Changed

1. `ansible/roles/caddy/tasks/main.yml`
   - Added service_facts gathering
   - Added conditional check for service existence

2. `ansible/roles/services/tasks/main.yml`
   - Added skip condition for Glance
   - Renamed variables to avoid shadowing
   - Cleaned up YAML formatting

3. `ansible/roles/services/templates/env.j2`
   - Updated to use renamed variables with `_var` suffix

## Best Practices Implemented

1. **Service Existence Check**: Always check if a service exists before attempting to manage it
2. **Role Separation**: Services managed by dedicated roles should be explicitly excluded from generic roles
3. **Variable Naming**: Use distinct variable names in task vars to avoid shadowing extra vars
4. **Error Handling**: Appropriate use of `ignore_errors` for non-critical failures

## Future Recommendations

1. Consider adding a `managed_by_role` field to service definitions in `group_vars/all.yml` to make it explicit which services are managed by dedicated roles
2. Add integration tests that validate the playbook execution
3. Consider using Ansible's `--check` mode in CI to validate changes before applying them

## References

- GitHub Actions Run: #20391837676 (2025-12-20T08:34:01Z)
- Commit: 75b1442 "Fix Ansible deployment workflow issues"
- Commit: 0bea489 "Clean up trailing whitespace in services role"
