#!/bin/bash
# Generic Service Deployment Script
# Handles both standard Docker Compose services and custom script-based deployments

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

if [ $# -lt 1 ]; then
    log_error "Usage: $0 <service-name> [services-file]"
    exit 1
fi

SERVICE_NAME="$1"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"
CONFIGS_DIR="$(dirname "$SERVICES_FILE")"
SCRIPTS_DIR="$(dirname "$0")"
TARGET_DIR="/opt/$SERVICE_NAME"

# Check if yq is available
if ! command -v yq &> /dev/null; then
    log_error "yq is required but not installed."
    exit 1
fi

# Read service configuration
log_header "Processing service: $SERVICE_NAME"

# Check if service exists in config
if ! yq eval ".services[] | select(.name == \"$SERVICE_NAME\")" "$SERVICES_FILE" &> /dev/null; then
    log_warn "Service $SERVICE_NAME not found in $SERVICES_FILE"
    exit 0
fi

ENABLED=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .enabled // true" "$SERVICES_FILE")
SKIP_DEPLOY=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .skip_deploy // false" "$SERVICES_FILE")
# Explicitly check for managed property, default to true if null
MANAGED=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .managed" "$SERVICES_FILE")
if [ "$MANAGED" = "null" ]; then MANAGED="true"; fi

if [ "$ENABLED" != "true" ]; then
    log_info "Service $SERVICE_NAME is disabled. Skipping."
    exit 0
fi

if [ "$SKIP_DEPLOY" = "true" ]; then
    log_info "Service $SERVICE_NAME marked for skip_deploy. Skipping."
    exit 0
fi

if [ "$MANAGED" = "false" ]; then
    log_info "Service $SERVICE_NAME is managed: false. Skipping deployment."
    exit 0
fi

# Check for custom setup script (legacy support)
CUSTOM_SCRIPT="$SCRIPTS_DIR/setup-$SERVICE_NAME.sh"
if [ -f "$CUSTOM_SCRIPT" ]; then
    log_info "Found custom setup script: $CUSTOM_SCRIPT"
    bash "$CUSTOM_SCRIPT" "$SERVICE_NAME" "$SERVICES_FILE"
    exit $?
fi

# Standard Docker Compose Deployment
log_info "Starting standard Docker Compose deployment for $SERVICE_NAME..."

SERVICE_CONFIG_DIR="$CONFIGS_DIR/$SERVICE_NAME"
HOOKS_DIR="$SERVICE_CONFIG_DIR/hooks"

if [ ! -d "$SERVICE_CONFIG_DIR" ]; then
    log_error "Configuration directory not found: $SERVICE_CONFIG_DIR"
    exit 1
fi

if [ ! -f "$SERVICE_CONFIG_DIR/docker-compose.yml" ]; then
    log_error "docker-compose.yml not found in $SERVICE_CONFIG_DIR"
    exit 1
fi

# === PRE-DEPLOY HOOK ===
PRE_DEPLOY_HOOK="$HOOKS_DIR/pre-deploy.sh"
if [ -f "$PRE_DEPLOY_HOOK" ]; then
    log_info "Running pre-deploy hook..."
    chmod +x "$PRE_DEPLOY_HOOK"
    if bash "$PRE_DEPLOY_HOOK" "$SERVICE_NAME" "$SERVICES_FILE"; then
        log_success "Pre-deploy hook completed successfully"
    else
        log_error "Pre-deploy hook failed"
        exit 1
    fi
fi

# Prepare target directory
log_info "Preparing directory: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# Copy configuration files (excluding hooks directory)
log_info "Copying configuration files..."
shopt -s dotglob nullglob
for item in "$SERVICE_CONFIG_DIR/"*; do
    # Skip hooks directory
    if [ "$(basename "$item")" != "hooks" ]; then
        cp -r "$item" "$TARGET_DIR/"
    fi
done
shopt -u dotglob nullglob

# Handle .env file
ENV_FILE="$TARGET_DIR/.env"
ENV_EXAMPLE="$TARGET_DIR/.env.example"

if [ ! -f "$ENV_FILE" ] && [ -f "$ENV_EXAMPLE" ]; then
    log_info "Creating .env from example..."
    
    # Use inject-secrets.sh if available
    INJECT_SCRIPT="$SCRIPTS_DIR/inject-secrets.sh"
    if [ -f "$INJECT_SCRIPT" ]; then
        log_info "Injecting secrets..."
        bash "$INJECT_SCRIPT" "$ENV_EXAMPLE" "$ENV_FILE"
    else
        log_warn "inject-secrets.sh not found, copying template directly..."
        cp "$ENV_EXAMPLE" "$ENV_FILE"
    fi
fi

# Validate secrets (check for placeholders)
if [ -f "$ENV_FILE" ]; then
    if grep -q "PLACEHOLDER_" "$ENV_FILE"; then
        log_error ".env file contains PLACEHOLDER values. Secrets were not injected correctly."
        log_info "Please check your GitHub Secrets configuration."
        exit 1
    fi
fi

# Check and auto-correct port mappings for Caddy host mode
EXPECTED_PORT=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .port" "$SERVICES_FILE")

if [ "$EXPECTED_PORT" != "null" ] && [ -n "$EXPECTED_PORT" ]; then
    log_info "Checking port configuration for Caddy host mode (Expected: $EXPECTED_PORT)..."
    
    COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
    
    # Check if port is exposed (including localhost-bound ports like 127.0.0.1:PORT:PORT)
    # We look for "PORT:" or "PORT" in the ports list, or "127.0.0.1:PORT:"
    PORT_FOUND=$(yq eval -r ".services[].ports[]" "$COMPOSE_FILE" 2>/dev/null | grep -E "^($EXPECTED_PORT(:|$)|127\.0\.0\.1:$EXPECTED_PORT:)" || true)
    
    if [ -z "$PORT_FOUND" ]; then
        log_warn "Port $EXPECTED_PORT is NOT exposed in docker-compose.yml"
        
        # Count services
        SERVICE_COUNT=$(yq eval '.services | length' "$COMPOSE_FILE")
        
        if [ "$SERVICE_COUNT" -eq 1 ]; then
            log_info "Single service detected. Attempting auto-correction..."
            SERVICE_KEY=$(yq eval '.services | keys | .[0]' "$COMPOSE_FILE")
            
            # Try to detect internal port from image or common patterns?
            # No, that's too risky.
            # However, if the user defined 'port: 8080' in services.yml, they likely expect it to be accessible on 8080.
            # If the internal port is different (e.g. 80), mapping 8080:8080 will fail to connect.
            
            log_warn "Warning: Auto-correcting port mapping to $EXPECTED_PORT:$EXPECTED_PORT"
            log_info "   If the container listens on a different internal port, this will fail."
            
            # Add port mapping
            yq eval -i ".services.$SERVICE_KEY.ports += [\"$EXPECTED_PORT:$EXPECTED_PORT\"]" "$COMPOSE_FILE"
            
            log_success "Added port mapping: $EXPECTED_PORT:$EXPECTED_PORT"
        else
            log_error "Cannot auto-correct ports for multi-service compose file."
            log_info "Please manually add 'ports: - \"$EXPECTED_PORT:<internal_port>\"' to $COMPOSE_FILE"
            exit 1
        fi
    else
        log_success "Port $EXPECTED_PORT is exposed ($PORT_FOUND)"
    fi
fi

# Deploy
log_info "Deploying stack..."
cd "$TARGET_DIR"
docker compose pull
docker compose up -d --remove-orphans

log_success "$SERVICE_NAME deployed successfully"

# === POST-DEPLOY HOOK ===
POST_DEPLOY_HOOK="$HOOKS_DIR/post-deploy.sh"
if [ -f "$POST_DEPLOY_HOOK" ]; then
    log_info "Running post-deploy hook..."
    chmod +x "$POST_DEPLOY_HOOK"
    if bash "$POST_DEPLOY_HOOK" "$SERVICE_NAME" "$SERVICES_FILE"; then
        log_success "Post-deploy hook completed successfully"
    else
        log_warn "Post-deploy hook failed (non-critical)"
    fi
fi

# Check for legacy post-deployment script
POST_SCRIPT="$SCRIPTS_DIR/post-setup-$SERVICE_NAME.sh"
if [ -f "$POST_SCRIPT" ]; then
    log_info "Found legacy post-deployment script: $POST_SCRIPT"
    bash "$POST_SCRIPT" "$SERVICE_NAME" "$SERVICES_FILE"
fi

# === VALIDATION HOOK ===
VALIDATE_HOOK="$HOOKS_DIR/validate.sh"
if [ -f "$VALIDATE_HOOK" ]; then
    log_info "Running validation hook..."
    chmod +x "$VALIDATE_HOOK"
    if bash "$VALIDATE_HOOK" "$SERVICE_NAME" "$SERVICES_FILE"; then
        log_success "Validation completed successfully"
    else
        log_warn "Validation failed (non-critical)"
    fi
fi
