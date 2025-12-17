#!/bin/bash
# Custom setup script for Mailcow
# This script is called by deploy-service.sh

set -e

SERVICE_NAME="$1"
SERVICES_FILE="${2:-/tmp/homelab-deploy/configs/services.yml}"
TARGET_DIR="/opt/$SERVICE_NAME"

echo "🐮 Starting Mailcow setup..."

# Get configuration from services.yml
MAILCOW_HOSTNAME=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .domain" "$SERVICES_FILE")
TIMEZONE=$(yq eval ".global.timezone // \"Europe/Berlin\"" "$SERVICES_FILE")

if [ -z "$MAILCOW_HOSTNAME" ] || [ "$MAILCOW_HOSTNAME" = "null" ]; then
    echo "❌ Error: Could not determine domain for $SERVICE_NAME from $SERVICES_FILE"
    exit 1
fi

echo "Configuration:"
echo "  Hostname: $MAILCOW_HOSTNAME"
echo "  Timezone: $TIMEZONE"

# Prepare directory
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# Clone repository if not exists
if [ ! -d ".git" ]; then
    echo "📦 Cloning Mailcow repository..."
    git clone https://github.com/mailcow/mailcow-dockerized .
else
    echo "📦 Updating Mailcow repository..."
    git pull
fi

# Generate config if not exists
if [ ! -f "mailcow.conf" ]; then
    echo "⚙️  Generating configuration..."
    # Automate generate_config.sh inputs using environment variables where possible
    export MAILCOW_HOSTNAME="$MAILCOW_HOSTNAME"
    export MAILCOW_TZ="$TIMEZONE"
    export SKIP_CLAMD=n
    export MAILCOW_BRANCH=master

    # The script might still ask for daemon.json creation if IPv6 is detected
    yes | ./generate_config.sh
    echo "✓ Configuration generated"
else
    echo "ℹ️  mailcow.conf already exists, skipping generation"
fi

# Deploy
echo "🚀 Starting Mailcow..."
docker compose pull
docker compose up -d --remove-orphans

echo "✅ Mailcow deployed successfully"
echo "Admin URL: https://$MAILCOW_HOSTNAME/admin"
echo "Default credentials: admin / moohoo"
