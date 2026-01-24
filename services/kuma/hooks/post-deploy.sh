#!/bin/bash
# Post-deployment hook for Uptime Kuma
# Installs dependencies and provisions monitors

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"

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

log_info "Running Uptime Kuma post-deployment setup..."

# Check for secrets
if [ -f "/tmp/homelab-deploy/secrets.env" ]; then
    source "/tmp/homelab-deploy/secrets.env"
fi

if [ -z "$KUMA_USERNAME" ] || [ -z "$KUMA_PASSWORD" ]; then
    log_warn "KUMA_USERNAME or KUMA_PASSWORD not set in secrets.env"
    log_warn "Skipping automatic provisioning. Please configure monitors manually."
    exit 0
fi

# Install Python dependencies
log_info "Installing Python dependencies..."
if command -v python3 &> /dev/null; then
    python3 -m pip install uptime-kuma-api-v2 pyyaml --quiet --break-system-packages 2>/dev/null || \
    python3 -m pip install uptime-kuma-api-v2 pyyaml --quiet
    log_success "Dependencies installed"
else
    log_error "python3 not found. Cannot install dependencies."
    exit 1
fi

# Wait for Uptime Kuma to be ready
log_info "Waiting for Uptime Kuma to start..."
MAX_RETRIES=30
COUNT=0
KUMA_URL="${KUMA_URL:-http://localhost:3001}"

while ! curl -s "$KUMA_URL" > /dev/null; do
    sleep 5
    COUNT=$((COUNT+1))
    if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
        log_error "Timeout waiting for Uptime Kuma at $KUMA_URL"
        exit 1
    fi
    log_info "Waiting... ($COUNT/$MAX_RETRIES)"
done

log_success "Uptime Kuma is up!"

# Run provisioning script
PROVISION_SCRIPT="/opt/$SERVICE_NAME/hooks/provision-kuma.py"
if [ -f "$PROVISION_SCRIPT" ]; then
    log_info "Running provisioning script..."
    export KUMA_URL
    export KUMA_USERNAME
    export KUMA_PASSWORD

    if python3 "$PROVISION_SCRIPT" "$SERVICES_FILE"; then
        log_success "Uptime Kuma provisioning completed"
    else
        log_warn "Uptime Kuma provisioning failed (likely due to fresh install/auth)"
        log_warn "Please configure monitors manually via the web UI"
        # Don't fail the deployment
    fi
else
    log_warn "Provisioning script not found: $PROVISION_SCRIPT"
    log_warn "Monitors will need to be configured manually"
fi

log_success "Uptime Kuma post-deployment completed"
