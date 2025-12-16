#!/bin/bash
# Docker Compose deployment script for Rocky Linux
# Deploys Caddy and other managed services

set -e

echo "========================================="
echo "Starting Docker Compose Deployment"
echo "========================================="

OS_TYPE="$1"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"
CONFIGS_DIR="${3:-/tmp/homelab-deploy/configs}"
CADDY_DIR="/opt/caddy"

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not installed"
    exit 1
fi

# Check if yq is available (needed for parsing services.yml)
if ! command -v yq &> /dev/null; then
    echo "Installing yq for YAML parsing..."
    wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    chmod +x /usr/local/bin/yq
fi

# Create Caddy directory structure
echo "Creating Caddy directory structure..."
mkdir -p "$CADDY_DIR"
mkdir -p "$CADDY_DIR/data"
mkdir -p "$CADDY_DIR/config"

# Ensure shared network exists
if ! docker network inspect caddy_network &> /dev/null; then
    echo "Creating caddy_network..."
    docker network create caddy_network
fi

# Deploy Caddy if compose file exists
if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
    echo "Deploying Caddy..."
    cd "$CADDY_DIR"
    docker compose pull
    docker compose up -d
    echo "✓ Caddy deployed"
else
    echo "No Caddy docker-compose.yml found at $CADDY_DIR"
    echo "Will be created by Caddy setup script"
fi

# Deploy other managed services
if [ -f "$SERVICES_FILE" ]; then
    echo "Checking for other managed services..."
    SERVICE_COUNT=$(yq eval '.services | length' "$SERVICES_FILE")
    
    if [ "$SERVICE_COUNT" -gt 0 ]; then
        for i in $(seq 0 $((SERVICE_COUNT - 1))); do
            SERVICE_NAME=$(yq eval ".services[$i].name" "$SERVICES_FILE")
            ENABLED=$(yq eval ".services[$i].enabled // true" "$SERVICES_FILE")
            MANAGED=$(yq eval ".services[$i].managed // true" "$SERVICES_FILE")
            
            if [ "$ENABLED" = "true" ] && [ "$MANAGED" = "true" ]; then
                # Check if a config directory exists for this service
                SERVICE_CONFIG_DIR="$CONFIGS_DIR/$SERVICE_NAME"
                TARGET_DIR="/opt/$SERVICE_NAME"
                
                if [ -d "$SERVICE_CONFIG_DIR" ] && [ -f "$SERVICE_CONFIG_DIR/docker-compose.yml" ]; then
                    echo "Deploying managed service: $SERVICE_NAME"
                    mkdir -p "$TARGET_DIR"
                    
                    # Copy all files including hidden ones (like .env.example)
                    shopt -s dotglob nullglob
                    cp -r "$SERVICE_CONFIG_DIR/"* "$TARGET_DIR/"
                    shopt -u dotglob nullglob
                    
                    # Handle .env generation from example
                    if [ ! -f "$TARGET_DIR/.env" ] && [ -f "$TARGET_DIR/.env.example" ]; then
                        echo "⚠️  No .env found for $SERVICE_NAME. Creating from .env.example..."
                        cp "$TARGET_DIR/.env.example" "$TARGET_DIR/.env"
                        echo "✓ Created .env for $SERVICE_NAME"
                    fi
                    
                    cd "$TARGET_DIR"
                    docker compose pull
                    docker compose up -d
                    echo "✓ $SERVICE_NAME deployed"
                else
                    # Only warn if it's not Caddy (handled separately) and not explicitly unmanaged
                    if [ "$SERVICE_NAME" != "caddy" ]; then
                        echo "ℹ️  Service $SERVICE_NAME is managed but no docker-compose.yml found in $SERVICE_CONFIG_DIR"
                    fi
                fi
            else
                echo "ℹ️  Skipping deployment for $SERVICE_NAME (Enabled: $ENABLED, Managed: $MANAGED)"
            fi
        done
    fi
else
    echo "Warning: Services file not found at $SERVICES_FILE"
fi

# Show running containers
echo ""
echo "Running containers:"
docker ps

echo "========================================="
echo "Docker Compose Deployment Complete!"
echo "========================================="
