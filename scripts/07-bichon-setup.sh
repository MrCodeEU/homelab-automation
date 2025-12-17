#!/bin/bash
# Bichon email archiver deployment script for Rocky Linux
# Deploys bichon container with provided configuration

set -e

echo "========================================="
echo "Starting Bichon Deployment"
echo "========================================="

BICHON_DIR="/opt/bichon"
COMPOSE_FILE="$BICHON_DIR/docker-compose.yml"
ENV_FILE="$BICHON_DIR/.env"
ENV_EXAMPLE="$BICHON_DIR/.env.example"
SERVICES_FILE="/tmp/homelab-deploy/configs/services.yml"

# Respect skip_deploy and enabled flags from services.yml
if [ -f "$SERVICES_FILE" ] && command -v yq &> /dev/null; then
  ENABLED=$(yq eval '.services[] | select(.name == "bichon") | .enabled // true' "$SERVICES_FILE" 2>/dev/null || echo "true")
  SKIP_DEPLOY=$(yq eval '.services[] | select(.name == "bichon") | .skip_deploy // false' "$SERVICES_FILE" 2>/dev/null || echo "false")
  if [ "$ENABLED" != "true" ] || [ "$SKIP_DEPLOY" = "true" ]; then
    echo "ℹ️  Bichon deployment skipped by configuration (enabled=$ENABLED, skip_deploy=$SKIP_DEPLOY)"
    exit 0
  fi
fi

# Check Docker
if ! systemctl is-active --quiet docker; then
  echo "Error: Docker is not running. Please run 02-docker-setup.sh first."
  exit 1
fi

# Prepare directories
mkdir -p "$BICHON_DIR"

# Copy configuration files (including dotfiles)
if [ -d "/tmp/homelab-deploy/configs/bichon" ]; then
  echo "Copying Bichon configuration files..."
  shopt -s dotglob nullglob
  cp -r /tmp/homelab-deploy/configs/bichon/* "$BICHON_DIR/"
  shopt -u dotglob nullglob
  echo "✓ Copied configuration files to $BICHON_DIR"
else
  echo "Error: Bichon configuration not found in /tmp/homelab-deploy/configs/bichon"
  exit 1
fi

# Ensure .env exists
if [ ! -f "$ENV_FILE" ]; then
  echo "⚠️  No .env found. Creating from .env.example..."
  
  # Check if inject-secrets.sh exists and use it, otherwise just copy
  if [ -f "/tmp/homelab-deploy/scripts/inject-secrets.sh" ]; then
    echo "Using secret injection script..."
    bash /tmp/homelab-deploy/scripts/inject-secrets.sh "$ENV_EXAMPLE" "$ENV_FILE"
  else
    echo "Note: inject-secrets.sh not found, copying template..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  echo "✓ Created $ENV_FILE"
fi

# Validate required envs
BICHON_ENCRYPT_PASSWORD=$(grep -E '^BICHON_ENCRYPT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")
BICHON_ROOT_DIR=$(grep -E '^BICHON_ROOT_DIR=' "$ENV_FILE" | cut -d '=' -f 2- | tr -d '"' | tr -d "'")

if [ -z "$BICHON_ENCRYPT_PASSWORD" ] || [ "$BICHON_ENCRYPT_PASSWORD" = "PLACEHOLDER_BICHON_ENCRYPT_PASSWORD" ]; then
  echo "❌ BICHON_ENCRYPT_PASSWORD is required. Set GitHub Secret BICHON_ENCRYPT_PASSWORD or edit $ENV_FILE"
  exit 1
fi

if [ -z "$BICHON_ROOT_DIR" ]; then
  echo "❌ BICHON_ROOT_DIR must be set. Edit $ENV_FILE"
  exit 1
fi

# Ensure network
if ! docker network inspect caddy_network &> /dev/null; then
  echo "Creating caddy_network..."
  docker network create caddy_network
fi

# Deploy
cd "$BICHON_DIR"
echo "Starting Bichon container..."
docker compose up -d

echo "Waiting for Bichon to be ready..."
sleep 5

if docker ps --format '{{.Names}}' | grep -q '^bichon$'; then
  echo "✓ Bichon is running"
  echo "Access: http://localhost:15630 (or via Caddy domain if configured)"
else
  echo "❌ Bichon failed to start"
  docker logs bichon || true
  exit 1
fi
