.PHONY: help check deploy deploy-vps deploy-home deploy-pi deploy-all install lint

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check: ## Check prerequisites and Ansible configuration
	@echo "Checking prerequisites..."
	@command -v ansible >/dev/null 2>&1 || { echo "❌ Ansible is not installed"; exit 1; }
	@command -v ansible-playbook >/dev/null 2>&1 || { echo "❌ ansible-playbook is not installed"; exit 1; }
	@[ -f ansible/inventory/hosts.yml ] || { echo "❌ ansible/inventory/hosts.yml not found"; exit 1; }
	@echo "✅ All prerequisites met"
	@echo ""
	@echo "Testing Ansible inventory..."
	@cd ansible && ansible-inventory --list > /dev/null && echo "✅ Inventory valid"

install: ## Install Ansible collections
	@echo "Installing Ansible collections..."
	@cd ansible && ansible-galaxy collection install -r requirements.yml
	@echo "✅ Collections installed"

lint: ## Lint Ansible playbooks
	@echo "Linting Ansible playbooks..."
	@cd ansible && ansible-playbook playbooks/site.yml --syntax-check
	@echo "✅ Syntax check passed"

ping: ## Test connectivity to all hosts
	@echo "Testing connectivity..."
	@cd ansible && ansible all -m ping

deploy: ## Deploy to all hosts (all roles)
	@echo "Deploying to all hosts..."
	@cd ansible && ansible-playbook playbooks/site.yml

deploy-vps: ## Deploy to VPS (mljr) only
	@echo "Deploying to VPS..."
	@cd ansible && ansible-playbook playbooks/site.yml --limit mljr

deploy-home: ## Deploy to home server only
	@echo "Deploying to home server..."
	@cd ansible && ansible-playbook playbooks/site.yml --limit homeserver

deploy-pi: ## Deploy to Raspberry Pi only
	@echo "Deploying to Raspberry Pi..."
	@cd ansible && ansible-playbook playbooks/site.yml --limit pi

deploy-caddy: ## Deploy only Caddy configuration
	@echo "Deploying Caddy configuration..."
	@cd ansible && ansible-playbook playbooks/site.yml --tags caddy

deploy-services: ## Deploy only services
	@echo "Deploying services..."
	@cd ansible && ansible-playbook playbooks/site.yml --tags services

dry-run: ## Run deployment in check mode (dry run)
	@echo "Running dry run..."
	@cd ansible && ansible-playbook playbooks/site.yml --check

verbose: ## Deploy with verbose output
	@echo "Deploying with verbose output..."
	@cd ansible && ansible-playbook playbooks/site.yml -vvv

clean: ## Remove temporary files
	@echo "Cleaning temporary files..."
	@find . -name "*.retry" -delete
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -delete
	@echo "✅ Cleanup complete"

