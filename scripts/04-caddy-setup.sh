#!/bin/bash
# Caddy setup script for Rocky Linux
# Deploys Caddy as a Docker container

set -e

echo "========================================="
echo "Starting Caddy Setup (Docker)"
echo "========================================="

CADDY_DIR="/opt/caddy"
CONFIG_SOURCE="${1:-}"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"

# Create directory structure
mkdir -p "$CADDY_DIR/data"
mkdir -p "$CADDY_DIR/config"

# Create docker-compose.yml for Caddy
echo "Creating Caddy docker-compose.yml..."
cat > "$CADDY_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - ./data:/data
      - ./config:/config
    networks:
      - caddy_network

networks:
  caddy_network:
    name: caddy_network
EOF

# Deploy Caddyfile if provided
if [ -n "$CONFIG_SOURCE" ] && [ -f "$CONFIG_SOURCE" ]; then
  echo "Deploying Caddyfile from: $CONFIG_SOURCE"
  cp "$CONFIG_SOURCE" "$CADDY_DIR/Caddyfile"
elif [ ! -f "$CADDY_DIR/Caddyfile" ]; then
  # Only create default if no Caddyfile exists at all
  echo "⚠️  No Caddyfile found, creating minimal default..."
  cat > "$CADDY_DIR/Caddyfile" << 'EOF'
# Default Caddyfile
# Edit this file and restart Caddy to apply changes

:80 {
  respond "Caddy is running!" 200
}
EOF
else
  echo "✓ Using existing Caddyfile at: $CADDY_DIR/Caddyfile"
  echo ""
  echo "Caddyfile contents preview (first 20 lines):"
  head -n 20 "$CADDY_DIR/Caddyfile"
  echo ""
fi

# Validate Caddyfile using Docker
echo "Validating Caddyfile..."
docker run --rm -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile

# Start Caddy
echo "Starting Caddy container..."
cd "$CADDY_DIR"
docker compose up -d

# Reload Caddy unconditionally to apply the config
if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
  echo "Reloading Caddy with updated configuration..."
  if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile; then
    echo "✓ Caddy reloaded"
  else
    echo "⚠️  docker compose exec reload failed, trying docker exec..."
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile || echo "⚠️  Caddy reload failed"
  fi
else
  echo "⚠️  Caddy container not running; skipping reload"
fi

# Optional per-service reloads (controlled by services.yml: services[].reload = true)
if [ -f "$SERVICES_FILE" ] && command -v yq &> /dev/null; then
  SERVICE_COUNT=$(yq eval '.services | length' "$SERVICES_FILE")
  if [ "$SERVICE_COUNT" -gt 0 ]; then
    echo "Checking for services that request reload..."
    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        RELOAD_FLAG=$(yq eval ".services[$i].reload // false" "$SERVICES_FILE")
        SKIP_DEPLOY=$(yq eval ".services[$i].skip_deploy // false" "$SERVICES_FILE")
        if [ "$RELOAD_FLAG" != "true" ] || [ "$SKIP_DEPLOY" = "true" ]; then
        continue
      fi
      SERVICE_NAME=$(yq eval ".services[$i].name" "$SERVICES_FILE")
      CONTAINER_NAME=$(yq eval ".services[$i].container_name // \"$SERVICE_NAME\"" "$SERVICES_FILE")
      if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Reloading container for service: $SERVICE_NAME (container: $CONTAINER_NAME)"
        if docker restart "$CONTAINER_NAME"; then
          echo "✓ Restarted $CONTAINER_NAME"
        else
          echo "⚠️  Failed to restart $CONTAINER_NAME"
        fi
      else
        echo "ℹ️  Container $CONTAINER_NAME not running; skipping reload"
      fi
    done
  fi
else
  echo "ℹ️  Services file not found or yq missing; skipping per-service reloads"
fi

# Show status
echo ""
echo "Caddy container status:"
docker compose ps

echo "========================================="
echo "Caddy Setup Complete!"
echo "Caddyfile location: $CADDY_DIR/Caddyfile"
echo "========================================="
