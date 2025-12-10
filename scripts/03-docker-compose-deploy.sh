#!/bin/bash
# Docker Compose deployment script
# Deploys Docker containers using docker-compose files

set -e

echo "========================================="
echo "Starting Docker Compose Deployment"
echo "========================================="

COMPOSE_DIR="${1:-/opt/docker-compose}"

echo "Using compose directory: $COMPOSE_DIR"

# Create compose directory if it doesn't exist
mkdir -p "$COMPOSE_DIR"

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not installed"
    exit 1
fi

# Function to deploy a compose file
deploy_compose() {
    local compose_file=$1
    local compose_name=$(basename $(dirname "$compose_file"))
    
    echo "Deploying: $compose_name"
    cd "$(dirname "$compose_file")"
    
    # Pull latest images
    docker compose pull
    
    # Start services
    docker compose up -d
    
    echo "Deployed: $compose_name"
}

# Deploy all docker-compose files in the directory
if [ -d "$COMPOSE_DIR" ]; then
    echo "Searching for docker-compose.yml files in $COMPOSE_DIR..."
    
    for compose_file in $(find "$COMPOSE_DIR" -name "docker-compose.yml" -o -name "docker-compose.yaml"); do
        deploy_compose "$compose_file"
    done
else
    echo "Compose directory does not exist: $COMPOSE_DIR"
fi

# Show running containers
echo ""
echo "Running containers:"
docker ps

echo "========================================="
echo "Docker Compose Deployment Complete!"
echo "========================================="
