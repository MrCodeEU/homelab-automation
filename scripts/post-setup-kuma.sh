#!/bin/bash
# Post-deployment setup for Uptime Kuma
# Installs dependencies and provisions monitors

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "Warning: common.sh not found"
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_header() { echo "=== $1 ==="; }
fi

SERVICE_NAME="$1"
SERVICES_FILE="$2"

log_header "Uptime Kuma Post-Setup"

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
if command -v pip3 &> /dev/null; then
    pip3 install uptime-kuma-api pyyaml
else
    log_error "pip3 not found. Cannot install dependencies."
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
    echo -n "."
done
echo ""
log_success "Uptime Kuma is up!"

# Run provisioning script
PROVISION_SCRIPT="$SCRIPT_DIR/provision-kuma.py"
if [ -f "$PROVISION_SCRIPT" ]; then
    log_info "Running provisioning script..."
    export KUMA_URL
    export KUMA_USERNAME
    export KUMA_PASSWORD
    
    if python3 "$PROVISION_SCRIPT" "$SERVICES_FILE"; then
        log_success "Uptime Kuma provisioning completed"
    else
        log_warn "Uptime Kuma provisioning failed (likely due to fresh install/auth). Please configure monitors manually."
        # Do not fail the deployment
    fi
else
    log_error "Provisioning script not found: $PROVISION_SCRIPT"
fi
