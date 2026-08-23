################################################################################
# Homelab Automation — Test Runner + Local Deploy
#
# Testing:
#   make test              Fast local tests — no Docker needed (CI default)
#   make test-e2e          Full Docker deployment test (Caddy template rendering)
#   make test-services     Ping all production services (requires VPN/Tailscale)
#
# Local deployment (replaces GitHub Actions when minutes are exhausted):
#   make deploy-check      Dry run — verifies vault + connectivity, no changes
#   make deploy            Full deploy, all hosts
#   make deploy-caddy      Caddy only (fast, safe first step)
#   make deploy-services   Services only, all hosts
#   make deploy-mljr       All roles, mljr only
#   make deploy-nuc        All roles, nuc only
#
# Prerequisites for local deploy:
#   Tailscale active (handles SSH auth automatically)
#   pip install ansible-core mitogen ansible-mitogen
#   ansible-galaxy collection install -r ansible/requirements.yml
#   ansible/inventory/group_vars/all/vault.yml created and encrypted
#
# Container management:
#   make up                Start test containers
#   make down              Stop and remove test containers
#   make clean             Remove containers, images, and generated test files
#
# Prerequisites for make test:
#   pip install pyyaml jinja2
#   ansible-playbook (with community.docker collection)
#
# Prerequisites for make test-e2e:
#   docker + docker-compose
#   Same Ansible setup as CI (see ansible/requirements.yml)
################################################################################

ANSIBLE_DIR        := ansible
TESTS_DIR          := tests
TEST_INV           := $(TESTS_DIR)/inventory/hosts.yml
TEST_PLAYBOOK      := $(TESTS_DIR)/playbooks/test-caddy.yml
COMPOSE            := docker compose -f $(TESTS_DIR)/docker-compose.yml
SSH_DIR            := $(TESTS_DIR)/ssh
SSH_KEY            := $(SSH_DIR)/id_ed25519
ANSIBLE_CFG        := ANSIBLE_CONFIG=$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg
# Disable Mitogen for container tests (not installed in containers)
E2E_ANSIBLE_OPTS   := -e ansible_strategy=linear

.PHONY: test test-quick test-e2e test-services test-services-verbose test-healthreport \
        docs-ansible-map view-ara up down clean help \
        _check-validate _check-templates _check-syntax _check-compose \
        _e2e-deploy _ssh-keys _wait-ssh \
        deploy deploy-check deploy-diff deploy-caddy deploy-services deploy-mljr deploy-nuc deploy-svc \
        openvox-check openvox-deploy

################################################################################
# DEFAULT: fast local tests (no Docker)
################################################################################

test: _check-validate _check-templates _check-syntax _check-compose
	@echo ""
	@echo "All fast tests passed."

## 1. Pre-commit service definition validation (port/domain uniqueness etc.)
_check-validate:
	@echo "==> [1/4] Service definition validation"
	bash ./.githooks/pre-commit

## 2. Jinja2 template rendering — catches empty snippets locally
_check-templates:
	@echo "==> [2/4] Caddy template rendering"
	python3 $(TESTS_DIR)/scripts/check_templates.py

## 3. Ansible syntax check across all playbooks
_check-syntax:
	@echo "==> [3/4] Ansible syntax check"
	@if ! command -v ansible-playbook >/dev/null 2>&1; then \
	    echo "SKIP  ansible-playbook not found (install ansible-core to enable)"; \
	else \
	    cd $(ANSIBLE_DIR) && \
	    $(ANSIBLE_CFG) \
	    ansible-playbook playbooks/site.yml --syntax-check \
	    -i inventory; \
	fi

## 4. YAML lint on all docker-compose.yml files
_check-compose:
	@echo "==> [4/4] docker-compose.yml syntax"
	@find services -name "docker-compose.yml" -print0 \
	    | xargs -0 -I{} sh -c 'python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" {} \
	      && echo "OK  {}" || (echo "FAIL  {}" && exit 1)'

################################################################################
# E2E: deploy Caddy role to Docker containers, verify snippets
################################################################################

test-e2e: up _wait-ssh _e2e-deploy down
	@echo ""
	@echo "E2E tests passed."

_ssh-keys:
	@mkdir -p $(SSH_DIR)
	@if [ ! -f $(SSH_KEY) ]; then \
	    echo "Generating test SSH keypair..."; \
	    ssh-keygen -t ed25519 -N "" -C "homelab-test" -f $(SSH_KEY); \
	    cp $(SSH_KEY).pub $(SSH_DIR)/authorized_keys; \
	fi

up: _ssh-keys
	@echo "==> Starting test containers"
	$(COMPOSE) up -d --build
	@echo "Containers started."

_wait-ssh:
	@echo "==> Waiting for SSH to be ready"
	@for port in 2201 2202; do \
	    echo -n "  port $$port: "; \
	    for i in $$(seq 1 30); do \
	        ssh -o StrictHostKeyChecking=no \
	            -o UserKnownHostsFile=/dev/null \
	            -o ConnectTimeout=2 \
	            -i $(SSH_KEY) \
	            -p $$port root@127.0.0.1 true 2>/dev/null && \
	        echo "ready" && break; \
	        echo -n "."; \
	        sleep 1; \
	    done; \
	done

_e2e-deploy:
	@echo "==> Running Caddy template deployment test"
	$(ANSIBLE_CFG) \
	    ansible-playbook -i $(TEST_INV) $(TEST_PLAYBOOK) \
	    $(E2E_ANSIBLE_OPTS) $(ANSIBLE_EXTRA_ARGS)

down:
	@echo "==> Stopping test containers"
	$(COMPOSE) down --remove-orphans

################################################################################
# Production service reachability (requires Tailscale / VPN)
################################################################################

test-services:
	@echo "==> Checking production service reachability"
	python3 $(TESTS_DIR)/scripts/check_services.py $(SERVICE_ARGS)

test-services-verbose:
	@echo "==> Checking production service reachability (verbose)"
	python3 $(TESTS_DIR)/scripts/check_services.py --verbose

# Health report unit tests. Pure logic (severity rules + run-over-run diff),
# no network and no container needed.
test-healthreport:
	@python3 -c "import yaml" 2>/dev/null || { echo "ERROR: pip install pyyaml"; exit 1; }
	@echo "==> Health report: severity rules"
	@cd services/healthreport && python3 tests/test_severity.py
	@echo "==> Health report: diff engine"
	@cd services/healthreport && python3 tests/test_diff.py
	@echo "==> Health report: log signature normalization"
	@cd services/healthreport && python3 tests/test_normalize.py
	@echo "==> Health report: maintenance windows"
	@cd services/healthreport && python3 tests/test_maintenance.py

docs-ansible-map:
	@echo "==> Generating Ansible inventory/service map"
	python3 scripts/generate-ansible-visuals.py

view-ara:
	@RUN_ID="$(RUN_ID)" ARA_PORT="$(ARA_PORT)" ARA_DIR="$(ARA_DIR)" \
	  ARA_WORKFLOW_NAME="$(ARA_WORKFLOW_NAME)" ARA_ARTIFACT_NAME="$(ARA_ARTIFACT_NAME)" \
	  ./scripts/view-ara.sh

################################################################################
# Local deployment (Tailscale + Ansible Vault, no GitHub Actions needed)
################################################################################

deploy-check:
	@./scripts/deploy-local.sh --check

deploy-diff:
	@./scripts/deploy-local.sh --check --diff

deploy:
	@./scripts/deploy-local.sh

deploy-caddy:
	@./scripts/deploy-local.sh --tags caddy

deploy-services:
	@./scripts/deploy-local.sh --tags services

deploy-mljr:
	@./scripts/deploy-local.sh --limit mljr

deploy-nuc:
	@./scripts/deploy-local.sh --limit nuc

deploy-svc:
	@test -n "$(SERVICE)" || (echo "Usage: make deploy-svc SERVICE=<name>"; exit 1)
	@./scripts/deploy-local.sh --tags services,caddy --extra-vars "changed_services=$(SERVICE)"

################################################################################
# OpenVox (Puppet-family) migration - agent-managed hosts only for now.
# nas/wd-mycloud have no agent at all and are driven by exec resources
# declared on nuc's own node block instead (see openvox/manifests/).
#
# NOW the real production deploy path: .github/workflows/deploy.yml calls
# openvox-sync.sh directly (2026-08-23), all 26 ansible/roles ported.
# ansible/ + make deploy above are kept as reference for a few weeks per
# the user's standing instruction, not deleted yet and no longer wired
# into CI.
################################################################################

OPENVOX_HOSTS      := mljr.tail33930.ts.net nuc.tail33930.ts.net ugreen.tail33930.ts.net

# Runs all 3 hosts in parallel (xargs -P4), then prints one pass/fail line
# per host so a `make openvox-check`/`openvox-deploy` run has a scannable
# fleet-wide result instead of just each host's own banner buried in the
# (now per-line-prefixed, see openvox-sync.sh) combined output above it.
# Exits non-zero if any host failed - fine to use in a script/CI context.
define openvox_run
	@results=$$(mktemp); \
	echo "$(OPENVOX_HOSTS)" | tr ' ' '\n' | xargs -P4 -I{} sh -c \
	  './scripts/openvox-sync.sh {} $(1); echo "{} $$?" >> '"$$results"; \
	echo ""; \
	echo "==> fleet summary ($(1)):"; \
	fail=0; \
	while read -r host code; do \
	  label=$${host%%.*}; \
	  if [ "$$code" = "0" ]; then \
	    echo "    $$label: OK"; \
	  else \
	    echo "    $$label: FAILED (exit $$code)"; \
	    fail=1; \
	  fi; \
	done < "$$results"; \
	rm -f "$$results"; \
	exit $$fail
endef

openvox-check:
	$(call openvox_run,noop)

openvox-deploy:
	$(call openvox_run,apply)

# Single-host convenience targets, e.g. `make openvox-check-mljr`.
openvox-check-mljr:
	@./scripts/openvox-sync.sh mljr.tail33930.ts.net noop

openvox-check-nuc:
	@./scripts/openvox-sync.sh nuc.tail33930.ts.net noop

openvox-check-ugreen:
	@./scripts/openvox-sync.sh ugreen.tail33930.ts.net noop

openvox-deploy-mljr:
	@./scripts/openvox-sync.sh mljr.tail33930.ts.net apply

openvox-deploy-nuc:
	@./scripts/openvox-sync.sh nuc.tail33930.ts.net apply

openvox-deploy-ugreen:
	@./scripts/openvox-sync.sh ugreen.tail33930.ts.net apply

################################################################################
# Housekeeping
################################################################################

clean: down
	$(COMPOSE) rm -f
	$(COMPOSE) down --rmi local 2>/dev/null || true
	rm -rf $(SSH_DIR)
	@echo "Cleaned up."

# Quick help
help:
	@echo "Testing:"
	@echo "  make test              — fast local tests (no Docker)"
	@echo "  make test-e2e          — deploy to containers, verify Caddy snippets"
	@echo "  make test-services     — ping production services (needs VPN)"
	@echo "  make docs-ansible-map  — regenerate docs/ansible-map.md"
	@echo "  make view-ara          — download latest ARA artifact and open the UI"
	@echo ""
	@echo "Local deployment (requires Tailscale + vault.yml):"
	@echo "  make deploy-check      — dry run, no changes"
	@echo "  make deploy-diff       — dry run with file diffs"
	@echo "  make deploy            — full deploy, all hosts"
	@echo "  make deploy-caddy      — Caddy only"
	@echo "  make deploy-services   — services only"
	@echo "  make deploy-mljr       — all roles, mljr only"
	@echo "  make deploy-nuc        — all roles, nuc only"
	@echo "  make deploy-svc SERVICE=<name>  — single service + Caddy snippet"
	@echo ""
	@echo "Containers:"
	@echo "  make up / make down    — manage test containers manually"
	@echo "  make clean             — remove everything"
