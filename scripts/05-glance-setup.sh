#!/bin/bash
# Glance Dashboard Deployment Script for Rocky Linux
# Deploys Glance as Docker container with auto-generated configuration

set -e

echo "========================================="
echo "Starting Glance Dashboard Deployment"
echo "========================================="

# Configuration
GLANCE_DIR="/opt/glance"
COMPOSE_FILE="$GLANCE_DIR/docker-compose.yml"
CONFIG_FILE="$GLANCE_DIR/glance.yml"

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    echo "Error: Docker is not running. Please run 02-docker-setup.sh first."
    exit 1
fi

# Check if configuration exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Glance configuration not found at $CONFIG_FILE"
    echo "Please run generate-configs.sh first."
    exit 1
fi

# Check if docker-compose exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Glance docker-compose.yml not found at $COMPOSE_FILE"
    echo "Please run generate-configs.sh first."
    exit 1
fi

echo "Glance directory: $GLANCE_DIR"
echo "Configuration: $CONFIG_FILE"
echo "Compose file: $COMPOSE_FILE"

# Ensure Caddy network exists (created by Caddy setup)
if ! docker network inspect caddy_network &> /dev/null; then
    echo "Creating caddy_network..."
    docker network create caddy_network
fi

# Stop existing Glance container if running
if docker ps -a --format '{{.Names}}' | grep -q '^glance$'; then
    echo "Stopping existing Glance container..."
    docker stop glance || true
    docker rm glance || true
fi

# Start Glance
echo ""
echo "Starting Glance dashboard..."
cd "$GLANCE_DIR"

# Export timezone for docker-compose
export TIMEZONE=$(timedatectl show --property=Timezone --value)

docker compose up -d

# Wait for container to be healthy
echo "Waiting for Glance to be ready..."
sleep 5

# Check if Glance is running
if docker ps --format '{{.Names}}' | grep -q '^glance$'; then
    echo "✓ Glance is running"
    
    # Show container status
    echo ""
    echo "Container status:"
    docker ps --filter "name=glance" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    echo ""
    echo "========================================="
    echo "Glance Dashboard Deployed Successfully!"
    echo "========================================="
    echo ""
    echo "Access Glance:"
    echo "  • Local: http://localhost:8080"
    echo "  • Behind Caddy: https://$(grep -A1 'name: Glance' /tmp/homelab-deploy/configs/services.yml | grep domain | awk '{print $2}')"
    echo ""
    echo "Useful commands:"
    echo "  • View logs: docker logs -f glance"
    echo "  • Restart: docker restart glance"
    echo "  • Stop: docker stop glance"
    echo "  • Config location: $CONFIG_FILE"
    
else
    echo "Error: Glance container failed to start"
    echo "Checking logs..."
    docker logs glance
    exit 1
fi
