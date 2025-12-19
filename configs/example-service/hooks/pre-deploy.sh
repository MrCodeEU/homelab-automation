#!/bin/bash
# Pre-deployment hook for example-service
# This script runs BEFORE docker compose up
# Use it for: preparation, validation, dependency checks

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"
TARGET_DIR="/opt/$SERVICE_NAME"

echo "🔧 Running pre-deployment checks for $SERVICE_NAME..."

# Example: Ensure required directories exist
mkdir -p "$TARGET_DIR/data"
mkdir -p "$TARGET_DIR/config"

# Example: Validate configuration
if [ ! -f "$TARGET_DIR/docker-compose.yml" ]; then
    echo "❌ docker-compose.yml not found!"
    exit 1
fi

# Example: Check for required environment variables
# if [ -z "$SOME_REQUIRED_VAR" ]; then
#     echo "❌ SOME_REQUIRED_VAR not set!"
#     exit 1
# fi

# Example: Pull latest images before deployment
echo "📦 Pulling latest image..."
cd "$TARGET_DIR"
docker compose pull

echo "✅ Pre-deployment checks passed"
