#!/bin/bash
# Docker Compose deployment script for Rocky Linux
# Currently deploys only Caddy reverse proxy

set -e

echo "========================================="
echo "Starting Docker Compose Deployment"
echo "========================================="

CADDY_DIR="/opt/caddy"

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not installed"
    exit 1
fi

# Create Caddy directory structure
echo "Creating Caddy directory structure..."
mkdir -p "$CADDY_DIR"
mkdir -p "$CADDY_DIR/data"
mkdir -p "$CADDY_DIR/config"

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

# Show running containers
echo ""
echo "Running containers:"
docker ps

echo "========================================="
echo "Docker Compose Deployment Complete!"
echo "========================================="
