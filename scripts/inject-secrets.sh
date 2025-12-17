#!/bin/bash
# Secret injection script for .env file generation
# Reads .env.example files and replaces placeholders with actual secrets from environment variables

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    # Fallback
    echo "Warning: common.sh not found"
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_header() { echo "=== $1 ==="; }
    set_error_trap() { set -e; }
fi

set_error_trap

if [ $# -lt 2 ]; then
    log_error "Usage: $0 <env-example-file> <output-env-file>"
    log_info "Example: $0 /tmp/nightscout/.env.example /opt/nightscout/.env"
    exit 1
fi

ENV_EXAMPLE="$1"
ENV_OUTPUT="$2"

if [ ! -f "$ENV_EXAMPLE" ]; then
    log_error ".env.example file not found: $ENV_EXAMPLE"
    exit 1
fi

log_header "Injecting secrets into .env file"
log_info "Source: $ENV_EXAMPLE"
log_info "Output: $ENV_OUTPUT"

# Load secrets from secrets.env if it exists
if [ -f "/tmp/homelab-deploy/secrets.env" ]; then
    log_info "Loading secrets from secrets.env..."
    set -a
    source /tmp/homelab-deploy/secrets.env
    set +a
    log_success "Secrets loaded"
fi

# Copy .env.example to .env
cp "$ENV_EXAMPLE" "$ENV_OUTPUT"

# Function to inject a secret
inject_secret() {
    local placeholder=$1
    local env_var=$2
    local value="${!env_var}"
    
    if [ -z "$value" ]; then
        log_warn "$env_var is not set, keeping placeholder"
        return
    fi
    
    # Escape special characters for sed
    # This is a basic escape, might need improvement for complex passwords
    escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
    
    sed -i "s/$placeholder/$escaped_value/g" "$ENV_OUTPUT"
    log_success "Injected $env_var"
}
    # Escape special characters for sed
    local escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
    
    # Replace placeholder in .env file
    sed -i "s|$placeholder|$escaped_value|g" "$ENV_OUTPUT"
    echo "✓ Injected $env_var"
}

# Nightscout secrets
inject_secret "PLACEHOLDER_API_SECRET" "NIGHTSCOUT_API_SECRET"
inject_secret "PLACEHOLDER_LINK_UP_USERNAME" "LINK_UP_USERNAME"
inject_secret "PLACEHOLDER_LINK_UP_PASSWORD" "LINK_UP_PASSWORD"
inject_secret "PLACEHOLDER_NIGHTSCOUT_API_TOKEN" "NIGHTSCOUT_API_TOKEN"
inject_secret "PLACEHOLDER_NIGHTSCOUT_DOMAIN" "NIGHTSCOUT_DOMAIN"

# Bichon secrets
inject_secret "PLACEHOLDER_BICHON_ENCRYPT_PASSWORD" "BICHON_ENCRYPT_PASSWORD"

echo ""
echo "✓ Secret injection completed"
echo "Generated: $ENV_OUTPUT"
