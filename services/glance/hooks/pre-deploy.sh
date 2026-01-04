#!/bin/bash
# Pre-deployment hook for Glance
# Validates that required files exist before deploying

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"
TARGET_DIR="/opt/$SERVICE_NAME"

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
