################################################################################
# Homelab Automation — Test Runner
#
# Targets:
#   make test              Fast local tests — no Docker needed (CI default)
#   make test-e2e          Full Docker deployment test (Caddy template rendering)
#   make test-services     Ping all production services (requires VPN/Tailscale)
#
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

.PHONY: test test-quick test-e2e test-services up down clean \
        _check-validate _check-templates _check-syntax _check-compose \
        _e2e-deploy _ssh-keys _wait-ssh

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
	@echo "make test              — fast local tests (no Docker)"
	@echo "make test-e2e          — deploy to containers, verify Caddy snippets"
	@echo "make test-services     — ping production services (needs VPN)"
	@echo "make up / make down    — manage test containers manually"
	@echo "make clean             — remove everything"
