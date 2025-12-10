.PHONY: help check deploy-vps deploy-home deploy-unraid deploy-all

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check: ## Check prerequisites and configuration
	@echo "Checking prerequisites..."
	@command -v ssh >/dev/null 2>&1 || { echo "❌ SSH is not installed"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "❌ Git is not installed"; exit 1; }
	@[ -f inventory.yml ] || { echo "❌ inventory.yml not found"; exit 1; }
	@[ -f ~/.ssh/id_rsa ] || [ -f ~/.ssh/id_ed25519 ] || { echo "⚠️  Warning: No SSH key found in ~/.ssh/"; }
	@echo "✅ All prerequisites met"
	@echo ""
	@echo "Configuration:"
	@echo "  Inventory file: inventory.yml"
	@echo "  Scripts directory: scripts/"
	@echo "  Configs directory: configs/"

scripts-executable: ## Make all scripts executable
	@chmod +x scripts/*.sh
	@echo "✅ All scripts are now executable"

deploy-vps: scripts-executable ## Deploy to VPS only
	@echo "Deploying to VPS..."
	@./scripts/deploy.sh vps all

deploy-home: scripts-executable ## Deploy to home server only
	@echo "Deploying to home server..."
	@./scripts/deploy.sh homeserver all

deploy-unraid: scripts-executable ## Deploy to Unraid NAS only
	@echo "Deploying to Unraid NAS..."
	@./scripts/deploy.sh unraid all

deploy-all: scripts-executable ## Deploy to all devices
	@echo "Deploying to all devices..."
	@./scripts/deploy.sh all all

test-ssh: ## Test SSH connectivity to all devices (requires inventory configuration)
	@echo "Testing SSH connections..."
	@echo "Note: Update this target with your actual hostnames from inventory.yml"

clean: ## Remove temporary files
	@echo "Cleaning temporary files..."
	@find . -name "*.tmp" -delete
	@find . -name "*.log" -delete
	@echo "✅ Cleanup complete"
