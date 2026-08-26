#!/bin/bash
# Pre-deployment hook for Glance
# Validates that required files exist before deploying

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

log_info "Running Glance pre-deployment checks..."

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    log_error "Docker is not running"
    exit 1
fi

# Ensure Caddy network exists
if ! docker network inspect caddy_network &> /dev/null; then
    log_info "Creating caddy_network..."
    docker network create caddy_network
fi

# Export timezone for docker-compose (will be copied to target)
TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/London")
export TIMEZONE

log_success "Pre-deployment checks passed"
