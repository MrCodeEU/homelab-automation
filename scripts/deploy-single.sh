#!/bin/bash
# Helper script for testing deployment locally or to a single device

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================="
echo "Homelab Deployment Helper"
echo "========================================="
echo ""

# Function to show usage
show_usage() {
    echo "Usage: $0 <hostname> <user> [roles]"
    echo ""
    echo "Arguments:"
    echo "  hostname  - Tailscale hostname or IP address"
    echo "  user      - SSH user (e.g., root)"
    echo "  roles     - Comma-separated roles (default: all)"
    echo "              Options: base, docker, caddy, all"
    echo ""
    echo "Examples:"
    echo "  $0 myserver.tailnet-xxx.ts.net root all"
    echo "  $0 192.168.1.100 admin base,docker"
    echo ""
}

# Check arguments
if [ $# -lt 2 ]; then
    show_usage
    exit 1
fi

HOSTNAME=$1
USER=$2
ROLES=${3:-all}

# Configuration
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Target: $USER@$HOSTNAME"
echo "Roles: $ROLES"
echo "SSH Key: $SSH_KEY"
echo ""

# Test SSH connectivity
echo "Testing SSH connectivity..."
if ! ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "echo 'SSH connection successful'" 2>/dev/null; then
    echo "Error: Cannot connect to $HOSTNAME"
    echo "Please check:"
    echo "  1. Tailscale is running and connected"
    echo "  2. SSH key is correct: $SSH_KEY"
    echo "  3. Host is reachable: $HOSTNAME"
    exit 1
fi
echo "SSH connection successful!"
echo ""

# Copy scripts to remote host
echo "Copying deployment scripts..."
ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "mkdir -p /tmp/homelab-deploy"
scp $SSH_OPTIONS -i "$SSH_KEY" -r "$SCRIPT_DIR"/*.sh "$USER@$HOSTNAME:/tmp/homelab-deploy/"

# Copy configs to remote host
if [ -d "$PROJECT_ROOT/configs" ]; then
    echo "Copying configuration files..."
    scp $SSH_OPTIONS -i "$SSH_KEY" -r "$PROJECT_ROOT/configs" "$USER@$HOSTNAME:/tmp/homelab-deploy/"
fi

echo ""
echo "========================================="
echo "Starting Deployment"
echo "========================================="
echo ""

# Execute deployment scripts based on roles
if [[ "$ROLES" == *"base"* ]] || [ "$ROLES" = "all" ]; then
    echo ">>> Executing base setup..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash /tmp/homelab-deploy/01-base-setup.sh"
    echo ""
fi

if [[ "$ROLES" == *"docker"* ]] || [ "$ROLES" = "all" ]; then
    echo ">>> Executing Docker setup..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash /tmp/homelab-deploy/02-docker-setup.sh"
    echo ""
    
    echo ">>> Deploying Docker Compose stacks..."
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash /tmp/homelab-deploy/03-docker-compose-deploy.sh"
    echo ""
fi

if [[ "$ROLES" == *"caddy"* ]] || [ "$ROLES" = "all" ]; then
    echo ">>> Executing Caddy setup..."
    CADDYFILE="/tmp/homelab-deploy/configs/caddy/Caddyfile"
    ssh $SSH_OPTIONS -i "$SSH_KEY" "$USER@$HOSTNAME" "bash /tmp/homelab-deploy/04-caddy-setup.sh $CADDYFILE"
    echo ""
fi

echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Verify services are running"
echo "  2. Check logs for any errors"
echo "  3. Access your services via web browser"
echo ""
