#!/bin/bash
set -e

# Pre-deploy hook for Authelia
# Generates users_database.yml with hashed admin password from AUTHELIA_ADMIN_PASSWORD

SERVICE_PATH="${2:-$SERVICE_PATH}"

# Check if AUTHELIA_ADMIN_PASSWORD is set
if [ -z "$AUTHELIA_ADMIN_PASSWORD" ]; then
    echo "ERROR: AUTHELIA_ADMIN_PASSWORD environment variable is not set"
    exit 1
fi

# Generate Argon2 hash using Authelia's built-in hash generator
# We'll use docker exec if the container exists, or create a temporary container
echo "Generating password hash for admin user..."

# Use Authelia's crypto hash generate command
PASSWORD_HASH=$(docker run --rm authelia/authelia:latest \
    authelia crypto hash generate argon2 --password "$AUTHELIA_ADMIN_PASSWORD" --random | \
    grep 'Digest:' | awk '{print $2}')

if [ -z "$PASSWORD_HASH" ]; then
    echo "ERROR: Failed to generate password hash"
    exit 1
fi

# Generate users_database.yml
cat > "${SERVICE_PATH}/users_database.yml" << EOF
users:
  admin:
    displayname: Admin
    # Password hash generated from AUTHELIA_ADMIN_PASSWORD
    password: "$PASSWORD_HASH"
    email: admin@mljr.eu
    groups:
      - admins
      - dev
EOF

echo "CHANGED: Generated users_database.yml with hashed password"
