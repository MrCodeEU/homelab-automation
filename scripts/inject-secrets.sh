#!/bin/bash
# Secret injection script for .env file generation
# Reads .env.example files and replaces placeholders with actual secrets from environment variables

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <env-example-file> <output-env-file>"
    echo "Example: $0 /tmp/nightscout/.env.example /opt/nightscout/.env"
    exit 1
fi

ENV_EXAMPLE="$1"
ENV_OUTPUT="$2"

if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "Error: .env.example file not found: $ENV_EXAMPLE"
    exit 1
fi

echo "========================================="
echo "Injecting secrets into .env file"
echo "========================================="
echo "Source: $ENV_EXAMPLE"
echo "Output: $ENV_OUTPUT"
echo ""

# Load secrets from secrets.env if it exists
if [ -f "/tmp/homelab-deploy/secrets.env" ]; then
    echo "Loading secrets from secrets.env..."
    set -a
    source /tmp/homelab-deploy/secrets.env
    set +a
    echo "✓ Secrets loaded"
fi

# Copy .env.example to .env
cp "$ENV_EXAMPLE" "$ENV_OUTPUT"

# Function to inject a secret
inject_secret() {
    local placeholder=$1
    local env_var=$2
    local value="${!env_var}"
    
    if [ -z "$value" ]; then
        echo "⚠️  Warning: $env_var is not set, keeping placeholder"
        return
    fi
    
    # Escape special characters for sed
    local escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
    
    # Replace placeholder in .env file
    sed -i "s|$placeholder|$escaped_value|g" "$ENV_OUTPUT"
    echo "✓ Injected $env_var"
}

# Nightscout secrets
inject_secret "PLACEHOLDER_API_SECRET" "NIGHTSCOUT_API_SECRET"
inject_secret "PLACEHOLDER_LINK_UP_USERNAME" "LINK_UP_USERNAME"
inject_secret "PLACEHOLDER_LINK_UP_PASSWORD" "LINK_UP_PASSWORD"
inject_secret "PLACEHOLDER_NIGHTSCOUT_API_TOKEN" "NIGHTSCOUT_API_TOKEN"
inject_secret "PLACEHOLDER_NIGHTSCOUT_DOMAIN" "NIGHTSCOUT_DOMAIN"

# Bichon secrets
inject_secret "PLACEHOLDER_BICHON_ENCRYPT_PASSWORD" "BICHON_ENCRYPT_PASSWORD"

echo ""
echo "✓ Secret injection completed"
echo "Generated: $ENV_OUTPUT"
