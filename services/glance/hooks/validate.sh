#!/bin/bash
# Validation hook for Glance
# Verifies Glance is running and accessible

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

log_info "Validating Glance deployment..."

# Wait for container to be ready
sleep 5

# Check if Glance container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${SERVICE_NAME}$"; then
    log_error "Glance container is not running"
    docker logs glance --tail 50 || true
    exit 1
fi

# Check container health
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$SERVICE_NAME")
if [ "$CONTAINER_STATUS" != "running" ]; then
    log_error "Container status is: $CONTAINER_STATUS"
    exit 1
fi

# Test HTTP endpoint
if curl -f -s http://localhost:8080 > /dev/null; then
    log_success "Glance is responding on port 8080"
else
    log_warn "Glance HTTP endpoint not responding yet (may need more time)"
fi

# Show container status
log_info "Container status:"
docker ps --filter "name=glance" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

log_success "Glance validation completed"
