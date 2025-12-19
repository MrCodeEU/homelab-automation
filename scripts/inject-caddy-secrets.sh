#!/bin/bash
# Inject authentication secrets into Caddyfile
# Replaces placeholders with actual credentials from environment variables

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "Warning: common.sh not found"
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1"; }
fi

CADDYFILE="${1:-/etc/caddy/Caddyfile}"

if [ ! -f "$CADDYFILE" ]; then
    log_error "Caddyfile not found: $CADDYFILE"
    exit 1
fi

log_info "Injecting secrets into Caddyfile: $CADDYFILE"

# Load secrets from secrets.env if it exists
if [ -f "/tmp/homelab-deploy/secrets.env" ]; then
    log_info "Loading secrets from secrets.env..."
    set -a
    source /tmp/homelab-deploy/secrets.env
    set +a
fi

# Check if authentication credentials are set
if [ -z "$CADDY_AUTH_USER" ] || [ -z "$CADDY_AUTH_PASSWORD_HASH" ]; then
    log_error "CADDY_AUTH_USER or CADDY_AUTH_PASSWORD_HASH not set in secrets"
    log_info "Generate hash with: caddy hash-password --plaintext 'your-password'"
    exit 1
fi

# Validate bcrypt hash format (should start with $2a$, $2b$, or $2y$)
if [[ ! "$CADDY_AUTH_PASSWORD_HASH" =~ ^\$2[aby]\$[0-9]{2}\$ ]]; then
    log_error "CADDY_AUTH_PASSWORD_HASH does not appear to be a valid bcrypt hash"
    log_info "It should start with \$2a\$, \$2b\$, or \$2y\$"
    log_info "Generate with: docker run --rm caddy caddy hash-password --plaintext 'your-password'"
    exit 1
fi

# Use Python for safe replacement (handles all special characters reliably)
python3 -c "
import sys, os, re
with open('$CADDYFILE', 'r') as f:
    content = f.read()
content = content.replace('__CADDY_AUTH_USER__', os.environ['CADDY_AUTH_USER'])
content = content.replace('__CADDY_AUTH_PASSWORD_HASH__', os.environ['CADDY_AUTH_PASSWORD_HASH'])
with open('$CADDYFILE', 'w') as f:
    f.write(content)
"

if [ $? -eq 0 ]; then
    log_success "Injected Caddy authentication credentials"
    log_info "Verifying Caddyfile syntax..."
    # Quick validation - check if placeholders are gone
    if grep -q "__CADDY_AUTH" "$CADDYFILE"; then
        log_error "Placeholders still present in Caddyfile after injection!"
        exit 1
    fi
else
    log_error "Failed to inject secrets into Caddyfile"
    exit 1
fi
