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

# Deploy Caddy if compose file exists
if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
    log_info "Deploying Caddy..."
    cd "$CADDY_DIR"
    docker compose pull
    docker compose up -d
    log_success "Caddy deployed"
else
    log_warn "No Caddy docker-compose.yml found at $CADDY_DIR"
    log_info "Will be created by Caddy setup script or generate-configs.sh"
fi

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

log_success "Docker Compose Deployment Complete!"
