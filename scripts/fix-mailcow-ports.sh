#!/bin/bash
# Fix Mailcow port binding conflict with Caddy
# Mailcow needs to use internal port 8080 instead of 80/443
# since Caddy handles SSL termination and proxying

set -e

echo "=== Fixing Mailcow Port Configuration ==="

MAILCOW_DIR="/opt/mailcow"

if [ ! -d "$MAILCOW_DIR" ]; then
    echo "❌ Mailcow not found at $MAILCOW_DIR"
    exit 1
fi

cd "$MAILCOW_DIR"

# Backup .env file
if [ -f .env ]; then
    echo "📦 Backing up .env to .env.backup-$(date +%Y%m%d-%H%M%S)"
    cp .env .env.backup-$(date +%Y%m%d-%H%M%S)
fi

# Update HTTP port to 8080 (Caddy will proxy to this)
echo "🔧 Updating HTTP_PORT from 80 to 8080..."
sed -i 's/^HTTP_PORT=80$/HTTP_PORT=8080/' .env

# Disable HTTPS port (Caddy handles SSL)
echo "🔧 Disabling HTTPS (Caddy handles SSL termination)..."
sed -i 's/^HTTPS_PORT=443$/HTTPS_PORT=/' .env

# Bind to localhost only (not 0.0.0.0)
echo "🔧 Binding to localhost only..."
sed -i 's/^HTTP_BIND=$/HTTP_BIND=127.0.0.1/' .env

echo "📋 New configuration:"
grep -E '^HTTP_PORT=|^HTTPS_PORT=|^HTTP_BIND=' .env

# Regenerate docker-compose with new ports
echo "🔄 Regenerating docker-compose.yml..."
docker compose pull
docker compose up -d

echo "✅ Mailcow port configuration updated"
echo ""
echo "Next steps:"
echo "1. Regenerate Caddyfile with: bash /tmp/homelab-deploy/scripts/generate-configs.sh"
echo "2. Reload Caddy: systemctl reload caddy"
echo ""
echo "Mailcow should now be accessible at:"
echo "  Internal: http://127.0.0.1:8080"
echo "  Public:   https://mail.mljr.eu (via Caddy)"
