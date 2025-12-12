#!/bin/bash
# Caddy setup script for Rocky Linux
# Deploys Caddy as a Docker container

set -e

echo "========================================="
echo "Starting Caddy Setup (Docker)"
echo "========================================="

CADDY_DIR="/opt/caddy"
CONFIG_SOURCE="${1:-}"
OLD_HASH=""
NEW_HASH=""
NEED_RELOAD="false"

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
      - ./data:/data
      - ./config:/config
    networks:
      - caddy_network

networks:
  caddy_network:
    name: caddy_network
EOF

# Capture current hash if present
if [ -f "$CADDY_DIR/Caddyfile" ]; then
  OLD_HASH=$(sha256sum "$CADDY_DIR/Caddyfile" | awk '{print $1}')
fi

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

# Compute new hash and decide if reload is needed
if [ -f "$CADDY_DIR/Caddyfile" ]; then
  NEW_HASH=$(sha256sum "$CADDY_DIR/Caddyfile" | awk '{print $1}')
  if [ "$OLD_HASH" != "$NEW_HASH" ]; then
    NEED_RELOAD="true"
    echo "Caddyfile changed (hash diff). Will reload after container is up."
  else
    echo "Caddyfile unchanged (hash match). Reload not required."
  fi
fi

# Validate Caddyfile using Docker
echo "Validating Caddyfile..."
docker run --rm -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile

# Start Caddy
echo "Starting Caddy container..."
cd "$CADDY_DIR"
docker compose up -d

# Reload Caddy only if config changed and container is running
if [ "$NEED_RELOAD" = "true" ]; then
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
fi

# Show status
echo ""
echo "Caddy container status:"
docker compose ps

echo "========================================="
echo "Caddy Setup Complete!"
echo "Caddyfile location: $CADDY_DIR/Caddyfile"
echo "========================================="
