#!/bin/bash
# Caddy setup script for Rocky Linux
# Deploys Caddy as a Docker container

set -e

echo "========================================="
echo "Starting Caddy Setup (Docker)"
echo "========================================="

CADDY_DIR="/opt/caddy"
CONFIG_SOURCE="${1:-}"

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

# Deploy Caddyfile if provided
if [ -n "$CONFIG_SOURCE" ] && [ -f "$CONFIG_SOURCE" ]; then
    echo "Deploying Caddyfile from: $CONFIG_SOURCE"
    cp "$CONFIG_SOURCE" "$CADDY_DIR/Caddyfile"
else
    # Create minimal default Caddyfile
    echo "Creating default Caddyfile..."
    cat > "$CADDY_DIR/Caddyfile" << 'EOF'
# Default Caddyfile
# Edit this file and restart Caddy to apply changes

:80 {
    respond "Caddy is running!" 200
}
EOF
fi

# Validate Caddyfile using Docker
echo "Validating Caddyfile..."
docker run --rm -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile

# Start Caddy
echo "Starting Caddy container..."
cd "$CADDY_DIR"
docker compose up -d

# Show status
echo ""
echo "Caddy container status:"
docker compose ps

echo "========================================="
echo "Caddy Setup Complete!"
echo "Caddyfile location: $CADDY_DIR/Caddyfile"
echo "========================================="
