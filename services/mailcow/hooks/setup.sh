#!/bin/bash
# Automated Mailcow Setup for Reverse Proxy Deployment
# This script fully automates Mailcow installation and configuration behind Caddy

set -e

SERVICE_NAME="${1:-mailcow}"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"
TARGET_DIR="/opt/$SERVICE_NAME"
HTTP_PORT="8081"  # Caddy proxies to this port

echo "========================================="
echo "🐮 Mailcow Automated Setup"
echo "========================================="

# Get configuration from services.yml
MAILCOW_HOSTNAME=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .domain" "$SERVICES_FILE")
TIMEZONE=$(yq eval ".global.timezone // \"Europe/Vienna\"" "$SERVICES_FILE")

if [ -z "$MAILCOW_HOSTNAME" ] || [ "$MAILCOW_HOSTNAME" = "null" ]; then
    echo "❌ Error: Could not determine domain for $SERVICE_NAME"
    exit 1
fi

echo "Configuration:"
echo "  Domain: $MAILCOW_HOSTNAME"
echo "  Timezone: $TIMEZONE"
echo "  HTTP Port: $HTTP_PORT (localhost only)"
echo "========================================="
echo ""

# Prepare directory
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# Clone repository if not exists
if [ ! -d ".git" ]; then
    echo "📥 Cloning Mailcow repository..."
    git clone https://github.com/mailcow/mailcow-dockerized .
    echo "✅ Repository cloned"
else
    echo "📦 Repository exists, pulling updates..."
    git pull || echo "⚠️  Could not pull updates (continuing anyway)"
fi

# Generate config if not exists
if [ ! -f "mailcow.conf" ]; then
    echo "⚙️  Generating Mailcow configuration..."
    # Fully automated config generation
    ./generate_config.sh <<GENERATE_EOF
$MAILCOW_HOSTNAME
$TIMEZONE
GENERATE_EOF
    echo "✅ Configuration generated"
else
    echo "ℹ️  mailcow.conf already exists"
fi

# Configure for reverse proxy
echo "🔧 Configuring for reverse proxy mode..."

# Backup config
cp mailcow.conf "mailcow.conf.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# Update mailcow.conf for reverse proxy
sed -i "s/^HTTP_PORT=.*/HTTP_PORT=$HTTP_PORT/" mailcow.conf
sed -i "s/^HTTP_BIND=.*/HTTP_BIND=127.0.0.1/" mailcow.conf
sed -i "s/^HTTPS_PORT=.*/HTTPS_PORT=/" mailcow.conf
sed -i "s/^HTTPS_BIND=.*/HTTPS_BIND=/" mailcow.conf
sed -i "s/^SKIP_LETS_ENCRYPT=.*/SKIP_LETS_ENCRYPT=y/" mailcow.conf
sed -i "s/^SNAT_TO_SOURCE=.*/SNAT_TO_SOURCE=/" mailcow.conf
sed -i "s/^SKIP_HTTP_VERIFICATION=.*/SKIP_HTTP_VERIFICATION=y/" mailcow.conf

echo "✅ mailcow.conf configured"

# Create docker-compose.override.yml
echo "📝 Creating docker-compose.override.yml..."
cat > docker-compose.override.yml <<'OVERRIDE_EOF'
services:
  nginx-mailcow:
    ports:
      # Bind only to localhost - Caddy handles external access
      - "127.0.0.1:8081:80"
    environment:
      - SKIP_LETS_ENCRYPT=y
      - SKIP_HTTP_VERIFICATION=y
OVERRIDE_EOF

echo "✅ Override file created"

# Pull and start
echo "📦 Pulling Docker images..."
docker compose pull

echo "🚀 Starting Mailcow services..."
docker compose up -d --remove-orphans

echo ""
echo "========================================="
echo "✅ Mailcow Setup Complete!"
echo "========================================="
echo ""
echo "🌐 Access:"
echo "  Internal: http://127.0.0.1:$HTTP_PORT"
echo "  Public:   https://$MAILCOW_HOSTNAME (via Caddy)"
echo ""
echo "🔑 Default credentials: admin / moohoo"
echo "   ⚠️  Change password immediately!"
echo ""
echo "📊 Check status: docker compose ps"
echo "📝 View logs: docker compose logs -f nginx-mailcow"
echo ""
echo "Admin URL: https://$MAILCOW_HOSTNAME/admin"
echo "Default credentials: admin / moohoo"
