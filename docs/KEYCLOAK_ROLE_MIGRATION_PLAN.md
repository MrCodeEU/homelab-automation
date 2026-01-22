# Keycloak Role Migration Plan

This document outlines the step-by-step approach to migrate Keycloak from the generic services deployment (with post-deploy hook) to a dedicated Ansible role.

## Current State

### Service Definition (`all.yml`)
```yaml
- name: keycloak
  enabled: true
  domain: "auth.mljr.eu"
  port: 9732
  host: mljr
  description: "SSO Identity Provider"
  icon: "mdi:shield-account"
  backup_critical: true
```

### Current Files
- `services/keycloak/docker-compose.yml` - Docker Compose config
- `services/keycloak/hooks/post-deploy.sh` - Provisioning script (191 lines)

### What the Post-Deploy Hook Does
1. Waits for Keycloak health endpoint (`/health/ready`)
2. Authenticates as admin, gets access token
3. Creates `homelab` realm (if not exists)
4. Creates `oauth2-proxy` client with:
   - Client secret (auto-generated)
   - Redirect URIs: `https://*.mljr.eu/oauth2/callback`
   - Web origins: `https://*.mljr.eu`
5. Optionally configures Google Identity Provider
6. Saves client secret to `/opt/keycloak/client-secret.txt`

### Secrets Used
- `KEYCLOAK_ADMIN_PASSWORD` - Admin password
- `KC_DB_PASSWORD` - Database password
- `GOOGLE_CLIENT_ID` - Optional, for Google IdP
- `GOOGLE_CLIENT_SECRET` - Optional, for Google IdP

---

## Target State

### New Structure
```
ansible/roles/keycloak/
├── tasks/
│   └── main.yml           # Main deployment + provisioning
├── templates/
│   └── docker-compose.yml.j2  # Templated compose file
├── defaults/
│   └── main.yml           # Default variables
└── handlers/
    └── main.yml           # Restart handlers
```

### Service Definition Changes
```yaml
- name: keycloak
  enabled: true
  domain: "auth.mljr.eu"
  port: 9732
  host: mljr
  description: "SSO Identity Provider"
  icon: "mdi:shield-account"
  backup_critical: true
  skip_deploy: true  # ADD THIS - uses dedicated role
```

### Playbook Addition (`site.yml`)
```yaml
- name: Keycloak Identity Provider
  hosts: mljr
  become: true
  gather_facts: false
  strategy: free
  tags:
    - keycloak
  roles:
    - keycloak
```

---

## Step-by-Step Implementation

### Phase 1: Create Role Structure

**Step 1.1: Create directory structure**
```bash
mkdir -p ansible/roles/keycloak/{tasks,templates,defaults,handlers}
```

**Step 1.2: Create `defaults/main.yml`**
```yaml
---
# Keycloak defaults
keycloak_install_path: "{{ base_path }}/keycloak"
keycloak_realm: "homelab"
keycloak_client_id: "oauth2-proxy"
keycloak_admin_user: "admin"
keycloak_internal_url: "http://localhost:9732"
keycloak_health_timeout: 300  # 5 minutes
keycloak_health_delay: 5

# Client configuration
keycloak_redirect_uris:
  - "https://*.mljr.eu/oauth2/callback"
keycloak_web_origins:
  - "https://*.mljr.eu"
keycloak_post_logout_uris: "https://*.mljr.eu/*"
```

**Step 1.3: Create `handlers/main.yml`**
```yaml
---
- name: Restart keycloak
  community.docker.docker_compose_v2:
    project_src: "{{ keycloak_install_path }}"
    state: restarted
```

### Phase 2: Create Main Tasks

**Step 2.1: Create `tasks/main.yml` - Structure**
```yaml
---
# Keycloak Role - Deploys and provisions Keycloak SSO

# 1. Get service config
# 2. Check if enabled
# 3. Create directory
# 4. Deploy docker-compose
# 5. Generate .env
# 6. Start containers
# 7. Wait for health
# 8. Get admin token
# 9. Create/verify realm
# 10. Create/verify client
# 11. Configure Google IdP (optional)
# 12. Save client secret
```

**Step 2.2: Implement directory and docker-compose deployment**
- Copy from `services/keycloak/docker-compose.yml` to template
- Use `ansible.builtin.template` to deploy
- Generate `.env` file with secrets

**Step 2.3: Implement health check**
```yaml
- name: Wait for Keycloak to be ready
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/health/ready"
    status_code: 200
  register: keycloak_health
  until: keycloak_health.status == 200
  retries: "{{ (keycloak_health_timeout / keycloak_health_delay) | int }}"
  delay: "{{ keycloak_health_delay }}"
  when: not ansible_check_mode
```

**Step 2.4: Implement admin authentication**
```yaml
- name: Get admin access token
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/realms/master/protocol/openid-connect/token"
    method: POST
    body_format: form-urlencoded
    body:
      client_id: admin-cli
      username: "{{ keycloak_admin_user }}"
      password: "{{ secrets.keycloak.admin_password }}"
      grant_type: password
    status_code: 200
  register: keycloak_token_response
  no_log: true
  when: not ansible_check_mode

- name: Set access token fact
  ansible.builtin.set_fact:
    keycloak_access_token: "{{ keycloak_token_response.json.access_token }}"
  no_log: true
  when: not ansible_check_mode
```

**Step 2.5: Implement realm creation**
```yaml
- name: Check if realm exists
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms/{{ keycloak_realm }}"
    method: GET
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
    status_code: [200, 404]
  register: realm_check
  when: not ansible_check_mode

- name: Create realm
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms"
    method: POST
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
      Content-Type: application/json
    body_format: json
    body:
      realm: "{{ keycloak_realm }}"
      enabled: true
      displayName: "Homelab SSO"
    status_code: 201
  when:
    - not ansible_check_mode
    - realm_check.status == 404
```

**Step 2.6: Implement client creation**
```yaml
- name: Check if client exists
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms/{{ keycloak_realm }}/clients?clientId={{ keycloak_client_id }}"
    method: GET
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
    status_code: 200
  register: client_check
  when: not ansible_check_mode

- name: Generate client secret
  ansible.builtin.set_fact:
    keycloak_client_secret: "{{ lookup('password', '/dev/null length=32 chars=ascii_letters,digits') }}"
  when:
    - not ansible_check_mode
    - client_check.json | length == 0
  no_log: true

- name: Create client
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms/{{ keycloak_realm }}/clients"
    method: POST
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
      Content-Type: application/json
    body_format: json
    body:
      clientId: "{{ keycloak_client_id }}"
      name: "OAuth2 Proxy"
      enabled: true
      protocol: openid-connect
      publicClient: false
      secret: "{{ keycloak_client_secret }}"
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      serviceAccountsEnabled: false
      redirectUris: "{{ keycloak_redirect_uris }}"
      webOrigins: "{{ keycloak_web_origins }}"
      attributes:
        post.logout.redirect.uris: "{{ keycloak_post_logout_uris }}"
    status_code: 201
  when:
    - not ansible_check_mode
    - client_check.json | length == 0
  register: client_created
```

**Step 2.7: Implement Google IdP (optional)**
```yaml
- name: Check if Google IdP exists
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms/{{ keycloak_realm }}/identity-provider/instances/google"
    method: GET
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
    status_code: [200, 404]
  register: google_idp_check
  when:
    - not ansible_check_mode
    - secrets.google.client_id | default('') | length > 0
    - secrets.google.client_secret | default('') | length > 0

- name: Configure Google identity provider
  ansible.builtin.uri:
    url: "{{ keycloak_internal_url }}/admin/realms/{{ keycloak_realm }}/identity-provider/instances"
    method: POST
    headers:
      Authorization: "Bearer {{ keycloak_access_token }}"
      Content-Type: application/json
    body_format: json
    body:
      alias: google
      displayName: Google
      providerId: google
      enabled: true
      trustEmail: true
      firstBrokerLoginFlowAlias: "first broker login"
      config:
        clientId: "{{ secrets.google.client_id }}"
        clientSecret: "{{ secrets.google.client_secret }}"
        defaultScope: "openid email profile"
        syncMode: IMPORT
    status_code: 201
  when:
    - not ansible_check_mode
    - google_idp_check is defined
    - google_idp_check.status == 404
```

**Step 2.8: Save client secret**
```yaml
- name: Save client secret to file
  ansible.builtin.copy:
    content: "OAUTH2_PROXY_CLIENT_SECRET={{ keycloak_client_secret }}"
    dest: "{{ keycloak_install_path }}/client-secret.txt"
    mode: '0600'
  when:
    - not ansible_check_mode
    - client_created is changed
  no_log: true

- name: Display client secret location
  ansible.builtin.debug:
    msg: |
      Keycloak provisioning complete!
      {% if client_created is changed %}
      NEW CLIENT SECRET saved to: {{ keycloak_install_path }}/client-secret.txt
      IMPORTANT: Update OAUTH2_PROXY_CLIENT_SECRET in your secrets!
      {% else %}
      Client already exists. Secret not changed.
      {% endif %}
```

### Phase 3: Update Configuration

**Step 3.1: Update `all.yml`**
- Add `skip_deploy: true` to keycloak service

**Step 3.2: Update `site.yml`**
- Add keycloak play (after glance, before services)

**Step 3.3: Move docker-compose to template**
- Copy `services/keycloak/docker-compose.yml` to `ansible/roles/keycloak/templates/docker-compose.yml.j2`
- Optionally templatize values

### Phase 4: Cleanup

**Step 4.1: Remove old hook**
- Delete `services/keycloak/hooks/` directory
- Keep `services/keycloak/docker-compose.yml` as backup/reference (or delete)

**Step 4.2: Update documentation**
- Update `CLAUDE.md` to mention keycloak role
- Update any deployment docs

### Phase 5: Testing

**Step 5.1: Dry run**
```bash
ansible-playbook playbooks/site.yml --tags keycloak --check --diff
```

**Step 5.2: Full deployment**
```bash
ansible-playbook playbooks/site.yml --tags keycloak
```

**Step 5.3: Verify**
- Check Keycloak UI at https://auth.mljr.eu
- Verify homelab realm exists
- Verify oauth2-proxy client exists
- Test oauth2-proxy authentication flow

---

## Rollback Plan

If issues occur:
1. Remove `skip_deploy: true` from keycloak in `all.yml`
2. Remove keycloak play from `site.yml`
3. Restore `services/keycloak/hooks/post-deploy.sh`
4. Redeploy with services role

---

## Files to Create/Modify

| Action | File |
|--------|------|
| CREATE | `ansible/roles/keycloak/tasks/main.yml` |
| CREATE | `ansible/roles/keycloak/defaults/main.yml` |
| CREATE | `ansible/roles/keycloak/handlers/main.yml` |
| CREATE | `ansible/roles/keycloak/templates/docker-compose.yml.j2` |
| MODIFY | `ansible/inventory/group_vars/all/all.yml` (add skip_deploy) |
| MODIFY | `ansible/playbooks/site.yml` (add keycloak play) |
| DELETE | `services/keycloak/hooks/` (after verification) |

---

## Estimated Implementation Time

- Phase 1 (Structure): 5 minutes
- Phase 2 (Tasks): 30-45 minutes
- Phase 3 (Config updates): 5 minutes
- Phase 4 (Cleanup): 5 minutes
- Phase 5 (Testing): 15-30 minutes

**Total: ~1-1.5 hours**
