#!/bin/bash
# Main deployment orchestration script
# Deploys homelab setup to all devices via SSH over Tailscale VPN

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================="
echo "Homelab Automation Deployment"
echo "========================================="

# Configuration
INVENTORY_FILE="${INVENTORY_FILE:-$PROJECT_ROOT/inventory.yml}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Check if yq is installed for YAML parsing
if ! command -v yq &> /dev/null; then
    echo "Warning: yq is not installed. Using basic parsing."
    echo "For better YAML parsing, install yq: https://github.com/mikefarah/yq"
    USE_YQ=false
else
    USE_YQ=true
fi

# Parse command line arguments
TARGET_DEVICE="${1:-all}"
ROLES="${2:-all}"

echo "Target Device: $TARGET_DEVICE"
echo "Roles: $ROLES"
echo ""

# Function to deploy to a single device
deploy_to_device() {
    local device_name=$1
    local hostname=$2
    local user=$3
    local os=$4
    local roles=$5
    
    echo "========================================="
    echo "Deploying to: $device_name ($hostname)"
    echo "OS: $os"
    echo "Roles: $roles"
    echo "========================================="
    
    # Test SSH connectivity
    echo "Testing SSH connectivity..."
    if ! ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "echo 'SSH connection successful'" 2>/dev/null; then
        echo "Error: Cannot connect to $hostname"
        return 1
    fi
    
    # Copy scripts to remote host
    echo "Copying deployment scripts..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "mkdir -p /tmp/homelab-deploy"
    scp $SSH_OPTIONS -i "$SSH_KEY" -r "$SCRIPT_DIR"/* "$user@$hostname:/tmp/homelab-deploy/"
    
    # Copy configs to remote host
    if [ -d "$PROJECT_ROOT/configs" ]; then
        echo "Copying configuration files..."
        scp $SSH_OPTIONS -i "$SSH_KEY" -r "$PROJECT_ROOT/configs" "$user@$hostname:/tmp/homelab-deploy/"
    fi
    
    # Execute deployment scripts based on roles
    if [[ "$roles" == *"base"* ]] || [ "$roles" = "all" ]; then
        echo "Executing base setup..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash /tmp/homelab-deploy/01-base-setup.sh $os"
    fi
    
    if [[ "$roles" == *"docker"* ]] || [ "$roles" = "all" ]; then
        echo "Executing Docker setup..."
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash /tmp/homelab-deploy/02-docker-setup.sh $os"
        
        # Use Unraid-specific deployment for Slackware/Unraid
        if [ "$os" = "slackware" ]; then
            echo "Deploying Docker containers for Unraid..."
            ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash /tmp/homelab-deploy/03-unraid-deploy.sh"
        else
            echo "Deploying Docker Compose stacks..."
            ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash /tmp/homelab-deploy/03-docker-compose-deploy.sh $os"
        fi
    fi
    
    if [[ "$roles" == *"caddy"* ]] || [ "$roles" = "all" ]; then
        echo "Executing Caddy setup..."
        # Check if Caddyfile exists for this device
        CADDYFILE="/tmp/homelab-deploy/configs/caddy/Caddyfile"
        ssh $SSH_OPTIONS -i "$SSH_KEY" "$user@$hostname" "bash /tmp/homelab-deploy/04-caddy-setup.sh $os $CADDYFILE"
    fi
    
    echo "Deployment to $device_name completed successfully!"
    echo ""
}

# Deploy to devices based on configuration
# Simple parsing for demonstration (replace with yq for production)
echo "Starting deployment process..."
echo ""

# Example deployment to predefined devices
# In production, this should parse inventory.yml
if [ "$TARGET_DEVICE" = "all" ] || [ "$TARGET_DEVICE" = "vps" ]; then
    echo "Deploy to VPS:"
    echo "Please configure your VPS details in inventory.yml"
    echo "Example: deploy_to_device 'vps' 'vps.tailnet-xxxx.ts.net' 'root' 'rocky' 'base,docker,caddy'"
fi

if [ "$TARGET_DEVICE" = "all" ] || [ "$TARGET_DEVICE" = "homeserver" ]; then
    echo "Deploy to Home Server:"
    echo "Please configure your home server details in inventory.yml"
    echo "Example: deploy_to_device 'homeserver' 'homeserver.tailnet-xxxx.ts.net' 'root' 'rocky' 'base,docker,caddy'"
fi

if [ "$TARGET_DEVICE" = "all" ] || [ "$TARGET_DEVICE" = "unraid" ]; then
    echo "Deploy to Unraid NAS:"
    echo "Please configure your Unraid details in inventory.yml"
    echo "Example: deploy_to_device 'unraid' 'unraid.tailnet-xxxx.ts.net' 'root' 'slackware' 'base,docker'"
fi

echo ""
echo "========================================="
echo "Note: This script requires manual configuration"
echo "Please edit inventory.yml with your device details"
echo "Then update this script to parse and use that configuration"
echo ""
echo "To deploy manually, use:"
echo "  $0 <device> <roles>"
echo "Example:"
echo "  $0 vps all"
echo "  $0 homeserver docker,caddy"
echo "========================================="
