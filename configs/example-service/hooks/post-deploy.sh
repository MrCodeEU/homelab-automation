#!/bin/bash
# Post-deployment hook for example-service
# This script runs AFTER docker compose up
# Use it for: initialization, data migration, notifications

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"
TARGET_DIR="/opt/$SERVICE_NAME"

echo "🚀 Running post-deployment tasks for $SERVICE_NAME..."

# Example: Wait for service to be healthy
echo "⏳ Waiting for service to start..."
sleep 3

# Example: Check if container is running
if docker ps | grep -q "$SERVICE_NAME"; then
    echo "✅ Container is running"
else
    echo "❌ Container failed to start"
    docker logs "$SERVICE_NAME" --tail 50
    exit 1
fi

# Example: Run initialization script inside container
# docker exec $SERVICE_NAME /app/init.sh

# Example: Create default data
echo "📝 Creating default content..."
docker exec "$SERVICE_NAME" sh -c "echo '<h1>Example Service</h1><p>Deployed successfully!</p>' > /usr/share/nginx/html/index.html"

# Example: Send notification
# curl -X POST -H "Title: Service Deployed" \
#      -d "$SERVICE_NAME deployed successfully" \
#      https://ntfy.mljr.eu/deployment

echo "✅ Post-deployment tasks completed"
