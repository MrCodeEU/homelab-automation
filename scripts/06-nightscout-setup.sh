#!/bin/bash
# Nightscout Deployment Script for Rocky Linux
# Deploys Nightscout + LibreLink Up connector + MongoDB stack

set -e

echo "========================================="
echo "Starting Nightscout Deployment"
echo "========================================="

# Respect skip_deploy in services.yml
SERVICES_FILE="/tmp/homelab-deploy/configs/services.yml"
if [ -f "$SERVICES_FILE" ] && command -v yq &> /dev/null; then
    NIGHTSCOUT_ENABLED=$(yq eval '.services[] | select(.name == "nightscout") | .enabled // true' "$SERVICES_FILE" 2>/dev/null || echo "true")
    NIGHTSCOUT_SKIP=$(yq eval '.services[] | select(.name == "nightscout") | .skip_deploy // false' "$SERVICES_FILE" 2>/dev/null || echo "false")
    if [ "$NIGHTSCOUT_ENABLED" != "true" ] || [ "$NIGHTSCOUT_SKIP" = "true" ]; then
        echo "ℹ️  Nightscout deployment skipped by configuration (enabled=$NIGHTSCOUT_ENABLED, skip_deploy=$NIGHTSCOUT_SKIP)"
        exit 0
    fi
fi

# Configuration
NIGHTSCOUT_DIR="/opt/nightscout"
COMPOSE_FILE="$NIGHTSCOUT_DIR/docker-compose.yml"
ENV_FILE="$NIGHTSCOUT_DIR/.env"
ENV_EXAMPLE="$NIGHTSCOUT_DIR/.env.example"

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    echo "Error: Docker is not running. Please run 02-docker-setup.sh first."
    exit 1
fi

# Create Nightscout directory
echo "Creating Nightscout directory..."
mkdir -p "$NIGHTSCOUT_DIR"

# Copy configuration files from deployment (including hidden files like .env.example)
if [ -d "/tmp/homelab-deploy/configs/nightscout" ]; then
    echo "Copying Nightscout configuration files..."
    # Copy all files including hidden ones using rsync or cp with dotglob
    shopt -s dotglob nullglob
    cp -r /tmp/homelab-deploy/configs/nightscout/* "$NIGHTSCOUT_DIR/"
    shopt -u dotglob nullglob
    echo "✓ Copied configuration files to $NIGHTSCOUT_DIR"
    ls -la "$NIGHTSCOUT_DIR/"
else
    echo "Error: Nightscout configuration not found in /tmp/homelab-deploy/configs/nightscout"
    exit 1
fi

# Check if .env file exists, if not create from example
if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo "⚠️  No .env file found. Creating from .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "✓ Created $ENV_FILE"
fi

# Check if .env.example has been configured with real values
if grep -q "your-secret-here-min-12-chars" "$ENV_FILE" 2>/dev/null || \
   grep -q "your-librelink-email@example.com" "$ENV_FILE" 2>/dev/null; then
    echo ""
    echo "⚠️  Configuration Required!"
    echo "========================================="
    echo "❌ The .env file still contains example values!"
    echo ""
    echo "Required settings:"
    echo "  1. API_SECRET - Your Nightscout password (min 12 characters)"
    echo "  2. LINK_UP_USERNAME - Your LibreLink Up email"
    echo "  3. LINK_UP_PASSWORD - Your LibreLink Up password"
    echo "  4. LINK_UP_REGION - Your region (EU, US, DE, etc.)"
    echo "  5. NIGHTSCOUT_API_TOKEN - SHA1 hash (already set)"
    echo "  6. NIGHTSCOUT_DOMAIN - Your domain (already set)"
    echo ""
    echo "Edit configuration:"
    echo "  nano $ENV_FILE"
    echo ""
    echo "Then run this script again."
    echo ""
    exit 1
fi

# Validate required environment variables
echo "Validating configuration..."

# Extract values from .env file safely (without sourcing)
API_SECRET=$(grep -E '^API_SECRET=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")
LINK_UP_USERNAME=$(grep -E '^LINK_UP_USERNAME=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")
LINK_UP_PASSWORD=$(grep -E '^LINK_UP_PASSWORD=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")
NIGHTSCOUT_API_TOKEN=$(grep -E '^NIGHTSCOUT_API_TOKEN=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")

if [ -z "$API_SECRET" ] || [ "$API_SECRET" = "your-secret-here-min-12-chars" ]; then
    echo "❌ Error: API_SECRET not configured in .env file"
    echo "Edit: nano $ENV_FILE"
    exit 1
fi

if [ ${#API_SECRET} -lt 12 ]; then
    echo "❌ Error: API_SECRET must be at least 12 characters long"
    exit 1
fi

if [ -z "$LINK_UP_USERNAME" ] || [ "$LINK_UP_USERNAME" = "your-librelink-email@example.com" ]; then
    echo "❌ Error: LINK_UP_USERNAME not configured in .env file"
    echo "Edit: nano $ENV_FILE"
    exit 1
fi

if [ -z "$LINK_UP_PASSWORD" ] || [ "$LINK_UP_PASSWORD" = "your-librelink-password" ]; then
    echo "❌ Error: LINK_UP_PASSWORD not configured in .env file"
    echo "Edit: nano $ENV_FILE"
    exit 1
fi

if [ -z "$NIGHTSCOUT_API_TOKEN" ]; then
    echo "❌ Error: NIGHTSCOUT_API_TOKEN not configured in .env file"
    echo "Generate it with: echo -n 'librelink-connector' | sha1sum | cut -d ' ' -f 1"
    echo "Edit: nano $ENV_FILE"
    exit 1
fi

echo "✓ Configuration validated"

# Ensure Caddy network exists
if ! docker network inspect caddy_network &> /dev/null; then
    echo "Creating caddy_network..."
    docker network create caddy_network
fi

# Check if containers are already running
if docker ps --format '{{.Names}}' | grep -q '^nightscout$'; then
    echo ""
    echo "Nightscout is already running. Updating..."
    cd "$NIGHTSCOUT_DIR"
    docker compose pull
    docker compose up -d
else
    # First time deployment
    echo ""
    echo "Starting Nightscout stack..."
    cd "$NIGHTSCOUT_DIR"
    docker compose up -d
fi

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 10

# Check if all containers are running
echo ""
echo "Checking container status..."
CONTAINERS=("nightscout-mongo" "nightscout" "nightscout-librelink-up")
ALL_RUNNING=true

for container in "${CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "✓ $container is running"
    else
        echo "❌ $container is NOT running"
        ALL_RUNNING=false
    fi
done

if [ "$ALL_RUNNING" = true ]; then
    echo ""
    echo "========================================="
    echo "Nightscout Deployed Successfully!"
    echo "========================================="
    echo ""
    echo "Services:"
    echo "  • Nightscout: http://localhost:1337"
    echo "  • MongoDB: (internal only)"
    echo "  • LibreLink Up Connector: (background service)"
    echo ""
    
    # Try to get domain from services.yml
    if [ -f "/tmp/homelab-deploy/configs/services.yml" ]; then
        DOMAIN=$(yq eval '.services[] | select(.name == "nightscout") | .domain' /tmp/homelab-deploy/configs/services.yml 2>/dev/null || echo "")
        if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
            echo "Public Access (after Caddy setup):"
            echo "  • https://$DOMAIN"
            echo ""
        fi
    fi
    
    echo "Useful commands:"
    echo "  • View Nightscout logs: docker logs -f nightscout"
    echo "  • View connector logs: docker logs -f nightscout-librelink-up"
    echo "  • View MongoDB logs: docker logs -f nightscout-mongo"
    echo "  • Check status: docker compose ps"
    echo "  • Restart: docker compose restart"
    echo "  • Stop: docker compose down"
    echo ""
    echo "Next steps:"
    echo "  1. Wait a few minutes for LibreLink Up to fetch data"
    echo "  2. Access Nightscout at http://localhost:1337"
    echo "  3. Configure Caddy for public HTTPS access"
    echo ""
    echo "Configuration file: $ENV_FILE"
    echo "Documentation: $NIGHTSCOUT_DIR/README.md"
    echo ""
else
    echo ""
    echo "❌ Some containers failed to start. Checking logs..."
    echo ""
    for container in "${CONTAINERS[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "=== $container logs ==="
            docker logs --tail 20 "$container" 2>&1 || echo "Container not found"
            echo ""
        fi
    done
    exit 1
fi
