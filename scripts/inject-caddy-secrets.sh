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
if [ -z "$CADDY_AUTH_USER" ] && [ -z "$CADDY_AUTH_PASSWORD_HASH" ]; then
    log_error "Both CADDY_AUTH_USER and CADDY_AUTH_PASSWORD_HASH are not set in secrets"
    log_info "Skipping injection (no credentials configured)"
    exit 0  # Exit gracefully - auth not configured
fi

log_info "Found credentials:"
log_info "  User: ${CADDY_AUTH_USER:-'<not set>'}"
log_info "  Hash: ${CADDY_AUTH_PASSWORD_HASH:+<set, length ${#CADDY_AUTH_PASSWORD_HASH}>}"

# Validate bcrypt hash format (should start with $2a$, $2b$, or $2y$)
HASH_VALID=true
if [ -n "$CADDY_AUTH_PASSWORD_HASH" ]; then
    if [[ ! "$CADDY_AUTH_PASSWORD_HASH" =~ ^\$2[aby]\$[0-9]{2}\$ ]]; then
        log_error "WARNING: CADDY_AUTH_PASSWORD_HASH does not appear to be a valid bcrypt hash"
        log_info "  It should start with \$2a\$, \$2b\$, or \$2y\$"
        log_info "  Current value starts with: ${CADDY_AUTH_PASSWORD_HASH:0:10}..."
        log_info "  Generate with: docker run --rm caddy caddy hash-password --plaintext 'your-password'"
        log_info "  Attempting injection anyway - Caddy will validate and provide better error"
        HASH_VALID=false
    fi
fi

# Export variables explicitly for Python subprocess
export CADDY_AUTH_USER
export CADDY_AUTH_PASSWORD_HASH

# Use Python for safe replacement (handles all special characters reliably)
python3 << 'PYTHON_SCRIPT'
import sys
import os

try:
    # Get environment variables
    username = os.environ.get('CADDY_AUTH_USER')
    password_hash = os.environ.get('CADDY_AUTH_PASSWORD_HASH')
    caddyfile_path = os.environ.get('CADDYFILE', '/etc/caddy/Caddyfile')
    
    if not username or not password_hash:
        print(f"ERROR: Missing credentials in Python environment", file=sys.stderr)
        print(f"  CADDY_AUTH_USER: {'SET' if username else 'NOT SET'}", file=sys.stderr)
        print(f"  CADDY_AUTH_PASSWORD_HASH: {'SET' if password_hash else 'NOT SET'}", file=sys.stderr)
        sys.exit(1)
    
    # Read Caddyfile
    with open(caddyfile_path, 'r') as f:
        content = f.read()
    
    # Check if placeholders exist before replacement
    if '__CADDY_AUTH_USER__' not in content and '__CADDY_AUTH_PASSWORD_HASH__' not in content:
        print(f"WARNING: No placeholders found in {caddyfile_path}", file=sys.stderr)
    
    # Perform replacement
    original_content = content
    content = content.replace('__CADDY_AUTH_USER__', username)
    content = content.replace('__CADDY_AUTH_PASSWORD_HASH__', password_hash)
    
    # Verify changes were made
    if content == original_content:
        print(f"WARNING: No changes made to Caddyfile", file=sys.stderr)
    else:
        # Show what was injected (safely)
        print(f"Injected username: {username}")
        print(f"Injected password hash: {password_hash[:15]}... (length: {len(password_hash)})")
    
    # Write back
    with open(caddyfile_path, 'w') as f:
        f.write(content)
    
    print(f"SUCCESS: Replaced credentials in {caddyfile_path}")
    sys.exit(0)
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT

if [ $? -eq 0 ]; then
    log_success "Injected Caddy authentication credentials"
    log_info "Verifying Caddyfile syntax..."
    # Quick validation - check if placeholders are gone
    if grep -q "__CADDY_AUTH" "$CADDYFILE"; then
        log_error "Placeholders still present in Caddyfile after injection!"
        grep "__CADDY_AUTH" "$CADDYFILE"
        exit 1
    fi
    log_success "Placeholders successfully replaced"
else
    log_error "Failed to inject secrets into Caddyfile"
    exit 1
fi
