#!/bin/bash
# Main deployment orchestration script
# Deploys homelab setup to all devices via SSH over Tailscale VPN

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

log_header "Homelab Automation Deployment"

# Configuration
INVENTORY_FILE="${INVENTORY_FILE:-$PROJECT_ROOT/inventory.yml}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Check if yq is installed for YAML parsing
if ! command -v yq &> /dev/null; then
    log_warn "yq is not installed. Using basic parsing."
    log_info "For better YAML parsing, install yq: https://github.com/mikefarah/yq"
    USE_YQ=false
else
    USE_YQ=true
fi

# Parse command line arguments
TARGET_DEVICE="${1:-all}"
TARGET_ROLES="${2:-all}"

log_info "Target Device: $TARGET_DEVICE"
log_info "Roles: $TARGET_ROLES"

# Function to deploy to a single device
deploy_to_device() {
    local device_name=$1
    local hostname=$2
    local user=$3
    local os=$4
    local roles=$5
    
    log_header "Deploying to: $device_name ($hostname)"
    log_info "OS: $os"
    log_info "Roles: $roles"
    
    # Test SSH connectivity
    log_info "Testing SSH connectivity..."
    if ! ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "echo 'SSH connection successful'" 2>/dev/null; then
        log_error "Cannot connect to $hostname"
        return 1
    fi
    
    # Copy scripts to remote host (preserve scripts/ prefix like CI workflow)
    log_info "Copying deployment scripts..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "mkdir -p $REMOTE_BASE"
    scp $SSH_OPTIONS -i "$SSH_KEY" -r "$SCRIPT_DIR" "$user@$hostname:$REMOTE_BASE/"
    
    # Copy configs to remote host
    if [ -d "$PROJECT_ROOT/configs" ]; then
        log_info "Copying configuration files..."
        scp $SSH_OPTIONS -i "$SSH_KEY" -r "$PROJECT_ROOT/configs" "$user@$hostname:$REMOTE_BASE/"
    fi

    # Copy inventory to remote host (needed for config generation)
    if [ -f "$INVENTORY_FILE" ]; then
        log_info "Copying inventory file..."
        scp $SSH_OPTIONS -i "$SSH_KEY" "$INVENTORY_FILE" "$user@$hostname:$REMOTE_BASE/inventory.yml"
    fi

    # Copy secrets.env if it exists (needed for secret injection)
    if [ -f "$PROJECT_ROOT/secrets.env" ]; then
        log_info "Copying secrets.env..."
        scp $SSH_OPTIONS -i "$SSH_KEY" "$PROJECT_ROOT/secrets.env" "$user@$hostname:$REMOTE_BASE/secrets.env"
    elif [ -f "secrets.env" ]; then
        # Fallback for when running from root
        log_info "Copying secrets.env..."
        scp $SSH_OPTIONS -i "$SSH_KEY" "secrets.env" "$user@$hostname:$REMOTE_BASE/secrets.env"
    fi
    
    # Execute deployment scripts based on roles
    if [[ "$roles" == *"base"* ]] || [ "$roles" = "all" ]; then
        log_info "Executing base setup..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/01-base-setup.sh $os"
    fi
    
    if [[ "$roles" == *"docker"* ]] || [ "$roles" = "all" ]; then
        log_info "Executing Docker setup..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/02-docker-setup.sh $os"
        
        # Use Unraid-specific deployment for Slackware/Unraid
        if [ "$os" = "slackware" ]; then
            log_info "Deploying Docker containers for Unraid..."
            ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/03-unraid-deploy.sh"
        else
            log_info "Deploying Docker Compose stacks..."
            ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/03-docker-compose-deploy.sh $os $REMOTE_CONFIGS/services.yml $REMOTE_CONFIGS"
        fi
    fi
    
    if [[ "$roles" == *"caddy"* ]] || [ "$roles" = "all" ]; then
        log_info "Executing Service Deployment..."
        # Generate configs (Caddyfile, Glance)
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/generate-configs.sh $REMOTE_CONFIGS/services.yml /opt/caddy /opt/glance $REMOTE_BASE/inventory.yml"
        
        # Deploy all services (Caddy, Glance, etc.)
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/03-docker-compose-deploy.sh $os $REMOTE_CONFIGS/services.yml $REMOTE_CONFIGS"
        
        # Apply environment-specific fixes
        log_info "Applying environment fixes..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash $REMOTE_SCRIPTS/post-deploy-fixes.sh"
    fi
    
    log_success "Deployment to $device_name completed successfully!"
}

# Parse Inventory and Deploy
log_info "Parsing inventory file: $INVENTORY_FILE"

if [ ! -f "$INVENTORY_FILE" ]; then
    log_error "Inventory file not found!"
    exit 1
fi

# Get list of devices
if [ "$USE_YQ" = true ]; then
    DEVICES=$(yq e '.devices | keys | .[]' "$INVENTORY_FILE")
else
    # Basic parsing: look for lines starting with 2 spaces and ending with colon, under "devices:"
    DEVICES=$(grep -A 100 "^devices:" "$INVENTORY_FILE" | grep -E "^  [a-zA-Z0-9_-]+:$" | sed 's/^  //;s/:$//')
fi

for DEVICE in $DEVICES; do
    # Skip if we are targeting a specific device and this isn't it
    if [ "$TARGET_DEVICE" != "all" ] && [ "$TARGET_DEVICE" != "$DEVICE" ]; then
        continue
    fi

    log_info "Processing device: $DEVICE"

    # Extract details
    if [ "$USE_YQ" = true ]; then
        HOSTNAME=$(yq e ".devices.$DEVICE.hostname" "$INVENTORY_FILE")
        USER=$(yq e ".devices.$DEVICE.user" "$INVENTORY_FILE")
        DESCRIPTION=$(yq e ".devices.$DEVICE.description" "$INVENTORY_FILE")
        ROLES_LIST=$(yq e ".devices.$DEVICE.roles[]" "$INVENTORY_FILE" | tr '\n' ',' | sed 's/,$//')
    else
        # Basic parsing using grep/sed
        DEVICE_BLOCK=$(sed -n "/^  $DEVICE:/,/^  [a-zA-Z]/p" "$INVENTORY_FILE")
        
        HOSTNAME=$(echo "$DEVICE_BLOCK" | grep "hostname:" | sed 's/.*hostname: "//;s/".*//')
        USER=$(echo "$DEVICE_BLOCK" | grep "user:" | sed 's/.*user: "//;s/".*//')
        DESCRIPTION=$(echo "$DEVICE_BLOCK" | grep "description:" | sed 's/.*description: "//;s/".*//')
        ROLES_LIST=$(echo "$DEVICE_BLOCK" | grep -A 10 "roles:" | grep "      - " | sed 's/.*- //' | tr '\n' ',' | sed 's/,$//')
    fi

    # Determine OS
    OS="auto"
    if [[ "$DESCRIPTION" == *"Rocky"* ]]; then OS="rocky"; fi
    if [[ "$DESCRIPTION" == *"Unraid"* ]]; then OS="slackware"; fi
    if [[ "$DESCRIPTION" == *"Debian"* ]]; then OS="debian"; fi
    if [[ "$DESCRIPTION" == *"Ubuntu"* ]]; then OS="ubuntu"; fi

    # Override roles if passed from command line
    if [ "$TARGET_ROLES" != "all" ]; then
        ROLES_TO_DEPLOY="$TARGET_ROLES"
    else
        ROLES_TO_DEPLOY="${ROLES_LIST:-all}"
    fi

    deploy_to_device "$DEVICE" "$HOSTNAME" "$USER" "$OS" "$ROLES_TO_DEPLOY"
done

log_success "All deployments finished."
