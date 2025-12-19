#!/bin/bash
# Helper script for testing deployment locally or to a single device

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

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REMOTE_BASE="/tmp/homelab-deploy"
REMOTE_SCRIPTS="$REMOTE_BASE/scripts"
REMOTE_CONFIGS="$REMOTE_BASE/configs"

# Track deployment start time for notifications
DEPLOYMENT_START_TIME=$(date +%s)

log_header "Homelab Deployment Helper"

# Function to show usage
show_usage() {
    echo "Usage: $0 <hostname> <user> [os] [roles]"
    echo ""
    echo "Arguments:"
    echo "  hostname  - Tailscale hostname or IP address"
    echo "  user      - SSH user (e.g., root)"
    echo "  os        - Operating system (rocky, slackware, ubuntu, debian)"
    echo "              Use 'auto' to auto-detect (default)"
    echo "  roles     - Comma-separated roles (default: all)"
    echo "              Options: base, docker, caddy, all"
    echo ""
    echo "Examples:"
    echo "  $0 myserver.tailnet-xxx.ts.net root rocky all"
    echo "  $0 unraid.tailnet-xxx.ts.net root slackware docker"
    echo "  $0 192.168.1.100 admin auto base,docker"
    echo ""
}

# Check arguments
if [ $# -lt 2 ]; then
    show_usage
    exit 1
fi

HOSTNAME=$1
USER=$2
OS=${3:-auto}
ROLES=${4:-all}

# If third argument looks like roles (not an OS), treat it as roles
# Check if it's a known OS type, otherwise assume it's roles
if [ "$OS" != "rocky" ] && [ "$OS" != "slackware" ] && [ "$OS" != "ubuntu" ] && [ "$OS" != "debian" ] && [ "$OS" != "auto" ]; then
    ROLES=$OS
    OS="auto"
fi

# Configuration
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

log_info "Target: $USER@$HOSTNAME"
log_info "OS: $OS"
log_info "Roles: $ROLES"
log_info "SSH Key: $SSH_KEY"

# Test SSH connectivity
log_info "Testing SSH connectivity..."
if ! ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to $HOSTNAME"
    log_info "Please check:"
    log_info "  1. Tailscale is running and connected"
    log_info "  2. SSH key is correct: $SSH_KEY"
    log_info "  3. Host is reachable: $HOSTNAME"
    exit 1
fi
log_success "SSH connection successful!"

# Copy scripts to remote host
log_info "Copying deployment scripts..."
ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "mkdir -p $REMOTE_BASE"
scp $SSH_OPTIONS -i "$SSH_KEY" -r "$SCRIPT_DIR" "$USER@$HOSTNAME:$REMOTE_BASE/"

# Copy configs to remote host
if [ -d "$PROJECT_ROOT/configs" ]; then
    log_info "Copying configuration files..."
    scp $SSH_OPTIONS -i "$SSH_KEY" -r "$PROJECT_ROOT/configs" "$USER@$HOSTNAME:$REMOTE_BASE/"
fi

# Copy inventory to remote host (needed for config generation)
if [ -f "$PROJECT_ROOT/inventory.yml" ]; then
    log_info "Copying inventory file..."
    scp $SSH_OPTIONS -i "$SSH_KEY" "$PROJECT_ROOT/inventory.yml" "$USER@$HOSTNAME:$REMOTE_BASE/inventory.yml"
fi

# Copy secrets.env if it exists
if [ -f "$PROJECT_ROOT/secrets.env" ]; then
    log_info "Copying secrets.env..."
    scp $SSH_OPTIONS -i "$SSH_KEY" "$PROJECT_ROOT/secrets.env" "$USER@$HOSTNAME:$REMOTE_BASE/secrets.env"
elif [ -f "secrets.env" ]; then
    log_info "Copying secrets.env..."
    scp $SSH_OPTIONS -i "$SSH_KEY" "secrets.env" "$USER@$HOSTNAME:$REMOTE_BASE/secrets.env"
fi

log_header "Starting Deployment"

# Execute deployment scripts based on roles
if [[ "$ROLES" == *"base"* ]] || [ "$ROLES" = "all" ]; then
    log_info ">>> Executing base setup..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/01-base-setup.sh $OS"
fi

if [[ "$ROLES" == *"docker"* ]] || [ "$ROLES" = "all" ]; then
    log_info ">>> Executing Docker setup..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/02-docker-setup.sh $OS"
    
    if [ "$OS" = "slackware" ]; then
        log_info "Deploying Docker containers for Unraid..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/03-unraid-deploy.sh"
    else
        log_info "Deploying Docker Compose stacks..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/03-docker-compose-deploy.sh $OS $REMOTE_CONFIGS/services.yml $REMOTE_CONFIGS"
    fi
fi

if [[ "$ROLES" == *"caddy"* ]] || [ "$ROLES" = "all" ]; then
    log_info ">>> Executing Service Deployment..."
    # Generate configs (Caddyfile, Glance)
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/generate-configs.sh $REMOTE_CONFIGS/services.yml /opt/caddy /opt/glance $REMOTE_BASE/inventory.yml"
    
    # Deploy all services (Caddy, Glance, etc.)
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash $REMOTE_SCRIPTS/03-docker-compose-deploy.sh $OS $REMOTE_CONFIGS/services.yml $REMOTE_CONFIGS"
fi

log_success "Deployment to $HOSTNAME completed successfully!"

# Send deployment notification via ntfy
DEPLOYMENT_END_TIME=$(date +%s)
DEPLOYMENT_DURATION=$((DEPLOYMENT_END_TIME - ${DEPLOYMENT_START_TIME:-$DEPLOYMENT_END_TIME}))
DEPLOYMENT_DURATION_MIN=$((DEPLOYMENT_DURATION / 60))
DEPLOYMENT_DURATION_SEC=$((DEPLOYMENT_DURATION % 60))

# Get deployment stats
CONTAINERS_COUNT=$(ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "docker ps --format '{{.Names}}' 2>/dev/null | wc -l" 2>/dev/null || echo "0")

NOTIFICATION_MSG="Host: $HOSTNAME
OS: $OS
Roles: $ROLES
Duration: ${DEPLOYMENT_DURATION_MIN}m ${DEPLOYMENT_DURATION_SEC}s
Containers: $CONTAINERS_COUNT running
Time: $(date '+%Y-%m-%d %H:%M:%S')"

log_info "Sending deployment notification..."
ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "
if command -v curl &> /dev/null; then
    curl -s -X POST \
        -H 'Title: ✅ Deployment Complete' \
        -H 'Priority: 3' \
        -H 'Tags: rocket,success' \
        -d '$NOTIFICATION_MSG' \
        https://ntfy.mljr.eu/deployment >/dev/null 2>&1 || true
fi
"

log_info "Next steps:"
log_info "  1. Verify services are running"
log_info "  2. Check logs for any errors"
log_info "  3. Access your services via web browser"
