#!/bin/bash
# Unraid Docker deployment script
# Deploys Docker containers using Unraid Community Applications templates

set -e

echo "========================================="
echo "Starting Unraid Docker Deployment"
echo "========================================="

TEMPLATES_DIR="${1:-/tmp/homelab-deploy/configs/docker}"

echo "Using templates directory: $TEMPLATES_DIR"

# Check if we're running on Unraid
if [ ! -f /etc/unraid-version ]; then
    echo "Warning: This script is designed for Unraid systems"
    echo "Current system may not be Unraid"
fi

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not available"
    echo "Please enable Docker in Unraid Settings > Docker"
    exit 1
fi

# Function to deploy a container using Unraid's docker run command
# This mimics how Unraid Community Applications work
deploy_unraid_container() {
    local service_name=$1
    local image=$2
    shift 2
    local docker_args="$@"
    
    echo "Deploying: $service_name"
    
    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${service_name}$"; then
        echo "Container $service_name already exists, stopping and removing..."
        docker stop "$service_name" 2>/dev/null || true
        docker rm "$service_name" 2>/dev/null || true
    fi
    
    # Pull the latest image
    echo "Pulling image: $image"
    docker pull "$image"
    
    # Run the container
    echo "Starting container: $service_name"
    eval "docker run -d --name=\"$service_name\" $docker_args \"$image\""
    
    echo "Deployed: $service_name"
}

# Deploy Portainer (Docker management UI)
echo ""
echo "=== Deploying Portainer ==="
deploy_unraid_container "portainer" "portainer/portainer-ce:latest" \
    "--restart=unless-stopped" \
    "-p 9000:9000" \
    "-p 9443:9443" \
    "-v /var/run/docker.sock:/var/run/docker.sock" \
    "-v /mnt/user/appdata/portainer:/data" \
    "-e TZ=UTC"

# Deploy Watchtower (Auto-update containers)
echo ""
echo "=== Deploying Watchtower ==="
deploy_unraid_container "watchtower" "containrrr/watchtower:latest" \
    "--restart=unless-stopped" \
    "-v /var/run/docker.sock:/var/run/docker.sock" \
    "-e WATCHTOWER_CLEANUP=true" \
    "-e WATCHTOWER_POLL_INTERVAL=86400" \
    "-e TZ=UTC"

# Deploy Homepage (Application dashboard)
echo ""
echo "=== Deploying Homepage ==="
# Create config directory for homepage
mkdir -p /mnt/user/appdata/homepage/config

deploy_unraid_container "homepage" "ghcr.io/gethomepage/homepage:latest" \
    "--restart=unless-stopped" \
    "-p 3000:3000" \
    "-v /mnt/user/appdata/homepage/config:/app/config" \
    "-v /var/run/docker.sock:/var/run/docker.sock:ro" \
    "-e TZ=UTC"

# Show running containers
echo ""
echo "Running containers:"
docker ps

echo ""
echo "========================================="
echo "Unraid Docker Deployment Complete!"
echo "========================================="
echo ""
echo "Access your services:"
echo "  - Portainer: http://<unraid-ip>:9000"
echo "  - Homepage: http://<unraid-ip>:3000"
echo ""
echo "Note: For additional applications, use the Unraid Community Applications"
echo "      interface to browse and install from the official templates."
echo "========================================="
