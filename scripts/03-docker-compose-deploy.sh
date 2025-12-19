#!/bin/bash
# Docker Compose deployment script
# Deploys Caddy and other managed services

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

log_header "Starting Docker Compose Deployment"

OS_TYPE="$1"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"
CONFIGS_DIR="${3:-/tmp/homelab-deploy/configs}"
CADDY_DIR="/opt/caddy"

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
    log_error "docker compose is not installed"
    exit 1
fi

# Check if yq is available (needed for parsing services.yml)
if ! command -v yq &> /dev/null; then
    log_info "Installing yq for YAML parsing..."
    if command -v wget &> /dev/null; then
        wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        chmod +x /usr/local/bin/yq
    else
        log_error "wget not found, cannot install yq. Please install yq manually."
        exit 1
    fi
fi

# Create Caddy directory structure
log_info "Creating Caddy directory structure..."
mkdir -p "$CADDY_DIR"
mkdir -p "$CADDY_DIR/data"
mkdir -p "$CADDY_DIR/config"

# Ensure shared network exists
if ! docker network inspect caddy_network &> /dev/null; then
    log_info "Creating caddy_network..."
    docker network create caddy_network
fi

# Caddy is now managed natively, so we skip docker deployment for it
# But we still need to ensure configs are generated and service is reloaded
log_info "Configuring native Caddy..."
if [ -f "$(dirname "$0")/setup-caddy.sh" ]; then
    if bash "$(dirname "$0")/setup-caddy.sh" "$CADDY_DIR/Caddyfile" "$SERVICES_FILE"; then
        log_success "Caddy configured successfully"
    else
        log_error "Caddy configuration failed"
        # We don't exit here because we want to attempt to deploy other services
        # although without Caddy they might not be accessible.
    fi
else
    log_warn "setup-caddy.sh not found, skipping Caddy reload"
fi

# --- Service Cleanup Logic ---
STATE_DIR="/opt/homelab-state"
STATE_FILE="$STATE_DIR/managed_services.txt"
mkdir -p "$STATE_DIR"

# Get current list of services from YAML
CURRENT_SERVICES=$(yq eval '.services[].name' "$SERVICES_FILE" | sort)

# Get previous list of services
if [ -f "$STATE_FILE" ]; then
    PREVIOUS_SERVICES=$(cat "$STATE_FILE" | sort)
else
    PREVIOUS_SERVICES=""
fi

# Identify removed services
# comm -23 produces lines in file1 (previous) but not in file2 (current)
if [ -n "$PREVIOUS_SERVICES" ]; then
    REMOVED_SERVICES=$(comm -23 <(echo "$PREVIOUS_SERVICES") <(echo "$CURRENT_SERVICES"))
    
    if [ -n "$REMOVED_SERVICES" ]; then
        log_header "Cleaning up removed services"
        for SERVICE in $REMOVED_SERVICES; do
            log_warn "Service '$SERVICE' was removed from configuration. Cleaning up..."
            SERVICE_DIR="/opt/$SERVICE"
            
            if [ -d "$SERVICE_DIR" ]; then
                # Stop containers if docker-compose exists
                if [ -f "$SERVICE_DIR/docker-compose.yml" ]; then
                    log_info "Stopping containers for $SERVICE..."
                    (cd "$SERVICE_DIR" && docker compose down) || log_warn "Failed to stop containers for $SERVICE"
                fi
                
                # Archive the directory
                ARCHIVE_DIR="/opt/archive/${SERVICE}_$(date +%Y%m%d_%H%M%S)"
                log_info "Archiving $SERVICE_DIR to $ARCHIVE_DIR..."
                mkdir -p "/opt/archive"
                mv "$SERVICE_DIR" "$ARCHIVE_DIR"
            else
                log_info "Directory for $SERVICE not found, nothing to clean up."
            fi
        done
    fi
fi

# Update state file with current services
echo "$CURRENT_SERVICES" > "$STATE_FILE"
# -----------------------------

# Deploy other managed services
DEPLOYMENT_REPORT=""
if [ -f "$SERVICES_FILE" ]; then
    log_info "Checking for other managed services..."
    SERVICE_COUNT=$(yq eval '.services | length' "$SERVICES_FILE")
    
    if [ "$SERVICE_COUNT" -gt 0 ]; then
        DEPLOYMENT_REPORT="<br><br><strong>Deployment Status:</strong><br>"
        for i in $(seq 0 $((SERVICE_COUNT - 1))); do
            SERVICE_NAME=$(yq eval ".services[$i].name" "$SERVICES_FILE")
            
            # Delegate to generic service deployment script
            # This handles:
            # 1. Checking enabled/managed/skip_deploy status
            # 2. Custom setup scripts (e.g. setup-mailcow.sh)
            # 3. Standard Docker Compose deployment
            # 4. Secret injection
            if bash "$(dirname "$0")/deploy-service.sh" "$SERVICE_NAME" "$SERVICES_FILE"; then
                log_success "Service $SERVICE_NAME processed successfully"
                DEPLOYMENT_REPORT="$DEPLOYMENT_REPORT <span style='color:#4caf50'>✓ $SERVICE_NAME</span><br>"
            else
                log_error "Service $SERVICE_NAME failed to process"
                DEPLOYMENT_REPORT="$DEPLOYMENT_REPORT <span style='color:#f44336'>✗ $SERVICE_NAME</span><br>"
                # We continue with other services instead of failing the whole deployment
            fi
        done
        
        # Update index.html with deployment report
        if [ -f "/opt/caddy/site/index.html" ]; then
            log_info "Updating index.html with deployment status..."
            # Escape slashes for sed
            ESCAPED_REPORT=$(echo "$DEPLOYMENT_REPORT" | sed 's/\//\\\//g')
            sed -i "s/<!-- DEPLOYMENT_STATUS -->/$ESCAPED_REPORT/" "/opt/caddy/site/index.html"
        fi
    fi
else
    log_warn "Services file not found at $SERVICES_FILE"
fi

# Show running containers
log_info "Running containers:"
docker ps

# Apply post-deployment environment fixes (idempotent)
if [ -f "$SCRIPT_DIR/post-deploy-fixes.sh" ]; then
    log_info "Applying environment fixes..."
    bash "$SCRIPT_DIR/post-deploy-fixes.sh"
fi

log_info "Restarting containers to apply configuration changes..."
if command -v docker &> /dev/null; then
    # Restart containers that need to pick up Caddyfile changes
    for container in "goaccess" "uptime-kuma"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            docker restart "${container}" >/dev/null 2>&1
            echo "  ✓ Restarted ${container}"
        fi
    done
fi

log_success "Docker Compose Deployment Complete!"
