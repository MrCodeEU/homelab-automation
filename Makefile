.PHONY: help check deploy deploy-vps deploy-staging install lint ping clean

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check: ## Check prerequisites and Ansible configuration
	@echo "Checking prerequisites..."
	@command -v ansible >/dev/null 2>&1 || { echo "Ansible is not installed"; exit 1; }
	@[ -f ansible/inventory/hosts.yml ] || { echo "ansible/inventory/hosts.yml not found"; exit 1; }
	@echo "All prerequisites met"
	@cd ansible && ansible-inventory --list > /dev/null && echo "Inventory valid"

install: ## Install Ansible collections
	@cd ansible && ansible-galaxy collection install -r requirements.yml

lint: ## Lint Ansible playbooks
	@cd ansible && ansible-playbook playbooks/site.yml --syntax-check

ping: ## Test connectivity to all hosts
	@cd ansible && ansible managed -m ping

deploy: ## Deploy to all hosts
	@cd ansible && ansible-playbook playbooks/site.yml

deploy-vps: ## Deploy to VPS (mljr) only
	@cd ansible && ansible-playbook playbooks/site.yml --limit mljr

deploy-staging: ## Deploy staging environment
	@cd ansible && ansible-playbook playbooks/site.yml -e is_staging_deployment=true

deploy-caddy: ## Deploy only Caddy configuration
	@cd ansible && ansible-playbook playbooks/site.yml --tags caddy

deploy-services: ## Deploy only services
	@cd ansible && ansible-playbook playbooks/site.yml --tags services

deploy-backup: ## Deploy backup configuration
	@cd ansible && ansible-playbook playbooks/site.yml --tags backup

dry-run: ## Run deployment in check mode
	@cd ansible && ansible-playbook playbooks/site.yml --check

verbose: ## Deploy with verbose output
	@cd ansible && ansible-playbook playbooks/site.yml -vvv

clean: ## Remove temporary files
	@find . -name "*.retry" -delete 2>/dev/null || true
	@find . -name "*.pyc" -delete 2>/dev/null || true
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleanup complete"
