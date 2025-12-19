#!/bin/bash
# Validation hook for example-service
# This script runs after post-deploy to verify the service is working
# Use it for: health checks, smoke tests, integration tests

set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"
TARGET_DIR="/opt/$SERVICE_NAME"

echo "🔍 Validating $SERVICE_NAME deployment..."

# Example: Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${SERVICE_NAME}$"; then
    echo "❌ Container is not running"
    exit 1
fi

# Example: Check container health
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$SERVICE_NAME")
if [ "$CONTAINER_STATUS" != "running" ]; then
    echo "❌ Container status is: $CONTAINER_STATUS"
    exit 1
fi

# Example: HTTP health check
echo "🌐 Testing HTTP endpoint..."
if curl -f -s http://localhost:8888 > /dev/null; then
    echo "✅ HTTP endpoint is responding"
else
    echo "❌ HTTP endpoint is not responding"
    exit 1
fi

# Example: Check logs for errors
echo "📋 Checking logs for errors..."
if docker logs "$SERVICE_NAME" --tail 100 | grep -i "error\|fatal\|exception" > /dev/null; then
    echo "⚠️  Found errors in logs (may be normal)"
    docker logs "$SERVICE_NAME" --tail 20
fi

# Example: Custom validation
# TEST_RESPONSE=$(curl -s http://localhost:8888/health)
# if [ "$TEST_RESPONSE" != "OK" ]; then
#     echo "❌ Health check failed: $TEST_RESPONSE"
#     exit 1
# fi

echo "✅ All validation checks passed"
