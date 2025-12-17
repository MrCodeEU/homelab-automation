#!/bin/bash
# Caddy setup script for Rocky Linux
# Deploys Caddy as a native system service

set -e

echo "========================================="
echo "Starting Caddy Setup (Native)"
echo "========================================="

CADDY_DIR="/opt/caddy"
CONFIG_SOURCE="${1:-}"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"

# Install Caddy if not present
if ! command -v caddy &> /dev/null; then
    echo "Installing Caddy..."
    dnf install -y 'dnf-command(config-manager)'
    dnf config-manager --add-repo https://dl.cloudsmith.io/public/caddy/stable/rpm/el/9/x86_64/caddy-stable.repo
    dnf install -y caddy
    systemctl enable --now caddy
else
    echo "✓ Caddy is already installed"
fi

# Create directory structure
mkdir -p "$CADDY_DIR/data"
mkdir -p "$CADDY_DIR/config"
mkdir -p "$CADDY_DIR/logs"
mkdir -p "$CADDY_DIR/site"

# Set permissions for caddy user
chown -R caddy:caddy "$CADDY_DIR"
chmod 755 "$CADDY_DIR"
chmod 755 "$CADDY_DIR/logs"

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
fi

# Link Caddyfile to /etc/caddy/Caddyfile
echo "Linking Caddyfile..."
ln -sf "$CADDY_DIR/Caddyfile" /etc/caddy/Caddyfile

# Validate Caddyfile
echo "Validating Caddyfile..."
caddy validate --config /etc/caddy/Caddyfile

# Reload Caddy
echo "Reloading Caddy..."
systemctl reload caddy || systemctl restart caddy

echo "✓ Caddy setup complete"

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
