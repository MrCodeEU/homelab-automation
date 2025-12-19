#!/bin/bash
# Fix Nightscout networking for system Caddy

echo "Fixing Nightscout networking..."

# Find Nightscout docker-compose file
NIGHTSCOUT_COMPOSE=$(docker inspect nightscout --format '{{.Config.Labels}}' | grep -oP '(?<=com.docker.compose.project.working_dir":")[^"]+')

if [ -z "$NIGHTSCOUT_COMPOSE" ]; then
    echo "Finding Nightscout by container inspection..."
    NIGHTSCOUT_DIR="/root/nightscout"
    if [ ! -d "$NIGHTSCOUT_DIR" ]; then
        echo "Error: Cannot find Nightscout docker-compose directory"
        exit 1
    fi
else
    NIGHTSCOUT_DIR="$NIGHTSCOUT_COMPOSE"
fi

echo "Nightscout directory: $NIGHTSCOUT_DIR"

# Backup original
cd "$NIGHTSCOUT_DIR" || exit 1
cp docker-compose.yml docker-compose.yml.backup

# Update ports to bind to localhost only (makes it accessible to system Caddy)
echo "Updating docker-compose.yml to bind to host..."
sed -i 's/- "1337:1337"/- "127.0.0.1:1337:1337"/' docker-compose.yml

# Restart containers
echo "Restarting Nightscout..."
docker-compose down
docker-compose up -d

echo "Waiting for Nightscout to start..."
sleep 10

# Test
echo "Testing Nightscout..."
curl -I http://127.0.0.1:1337 || echo "Nightscout not responding yet"

echo "Done! Test at https://nightscout.mljr.eu"
