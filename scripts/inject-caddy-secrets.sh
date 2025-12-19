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

# Escape special characters for sed
ESCAPED_USER=$(printf '%s\n' "$CADDY_AUTH_USER" | sed -e 's/[\/&]/\\&/g')
ESCAPED_HASH=$(printf '%s\n' "$CADDY_AUTH_PASSWORD_HASH" | sed -e 's/[\/&]/\\&/g')

# Replace placeholders
sed -i "s/__CADDY_AUTH_USER__/$ESCAPED_USER/g" "$CADDYFILE"
sed -i "s/__CADDY_AUTH_PASSWORD_HASH__/$ESCAPED_HASH/g" "$CADDYFILE"

log_success "Injected Caddy authentication credentials"
