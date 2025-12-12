#!/bin/bash
# Configuration generator script
# Reads services.yml and generates Caddyfile, Glance config, and docker-compose configurations

set -e

echo "========================================="
echo "Generating Configurations from YAML"
echo "========================================="

CONFIG_FILE="${1:-/tmp/homelab-deploy/configs/services.yml}"
CADDY_OUTPUT_DIR="${2:-/opt/caddy}"
GLANCE_OUTPUT_DIR="${3:-/opt/glance}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "Installing yq for YAML parsing..."
    wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    chmod +x /usr/local/bin/yq
fi

echo "Reading configuration from: $CONFIG_FILE"
mkdir -p "$CADDY_OUTPUT_DIR"
mkdir -p "$GLANCE_OUTPUT_DIR"

# Extract global configuration
DOMAIN=$(yq eval '.global.domain // "example.com"' "$CONFIG_FILE")
EMAIL=$(yq eval '.global.email // "admin@example.com"' "$CONFIG_FILE")
LOCATION=$(yq eval '.global.location // "London, United Kingdom"' "$CONFIG_FILE")
DASHBOARD_NAME=$(yq eval '.dashboard.name // "Homelab Dashboard"' "$CONFIG_FILE")
TIMEZONE=$(yq eval '.dashboard.timezone // "Europe/London"' "$CONFIG_FILE")

# Generate Caddyfile
echo "Generating Caddyfile..."
CADDYFILE="$CADDY_OUTPUT_DIR/Caddyfile"

# Start Caddyfile
cat > "$CADDYFILE" << EOF
# Auto-generated Caddyfile
# Generated from services.yml
# Email for Let's Encrypt: $EMAIL

{
    email $EMAIL
}

EOF

# Parse services and generate Caddy blocks
SERVICE_COUNT=$(yq eval '.services | length' "$CONFIG_FILE")

if [ "$SERVICE_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        SERVICE_NAME=$(yq eval ".services[$i].name" "$CONFIG_FILE")
        DOMAIN=$(yq eval ".services[$i].domain // \"\"" "$CONFIG_FILE")
        PORT=$(yq eval ".services[$i].port // \"\"" "$CONFIG_FILE")
        HOST=$(yq eval ".services[$i].host // \"localhost\"" "$CONFIG_FILE")
        UPSTREAM=$(yq eval ".services[$i].upstream // \"\"" "$CONFIG_FILE")
        ENABLED=$(yq eval ".services[$i].enabled // true" "$CONFIG_FILE")
        
        # Skip if not enabled or no domain
        if [ "$ENABLED" != "true" ] || [ -z "$DOMAIN" ]; then
            continue
        fi
        
        # Determine the upstream target
        if [ -n "$UPSTREAM" ]; then
            # Use custom upstream URL
            TARGET="$UPSTREAM"
        elif [ -n "$PORT" ]; then
            # Build target from host:port
            if [ "$HOST" = "localhost" ] || [ "$HOST" = "null" ]; then
                TARGET="localhost:$PORT"
            else
                TARGET="$HOST:$PORT"
            fi
        else
            echo "⚠️  Skipping $SERVICE_NAME: No port or upstream defined"
            continue
        fi
        
        # Add to Caddyfile
        echo "" >> "$CADDYFILE"
        echo "# $SERVICE_NAME" >> "$CADDYFILE"
        echo "$DOMAIN {" >> "$CADDYFILE"
        echo "    reverse_proxy $TARGET" >> "$CADDYFILE"
        echo "}" >> "$CADDYFILE"
        
        # Log what was added
        if [ -n "$UPSTREAM" ]; then
            echo "✓ Caddy: Added $SERVICE_NAME: $DOMAIN -> $UPSTREAM"
        else
            echo "✓ Caddy: Added $SERVICE_NAME: $DOMAIN -> $TARGET"
        fi
    done
else
    echo "No services found in configuration"
fi

echo "Caddyfile generated at: $CADDYFILE"

# Generate Glance configuration
echo ""
echo "Generating Glance configuration..."
GLANCE_CONFIG="$GLANCE_OUTPUT_DIR/glance.yml"

# Check if template exists
TEMPLATE_PATH="/tmp/homelab-deploy/configs/glance/glance.yml.template"
if [ -f "$TEMPLATE_PATH" ]; then
    # Use template and replace variables
    cat "$TEMPLATE_PATH" | \
        sed "s/\${LOCATION}/$LOCATION/g" | \
        sed "s/\${SERVER_NAME}/$(hostname)/g" | \
        sed "s/\${DASHBOARD_NAME}/$DASHBOARD_NAME/g" > "$GLANCE_CONFIG"
    
    echo "✓ Glance config generated from template at: $GLANCE_CONFIG"
else
    # Create minimal Glance config
    cat > "$GLANCE_CONFIG" << EOF
# Glance Dashboard Configuration
# Auto-generated from services.yml

server:
  port: 8080

theme:
  background-color: 240 8 9
  primary-color: 43 50 70

pages:
  - name: Home
    columns:
      - size: small
        widgets:
          - type: weather
            location: $LOCATION
            
      - size: full
        widgets:
          - type: docker-containers
            title: Services
            
      - size: small
        widgets:
          - type: monitor
            title: Health
            sites:
EOF

    # Add monitored services
    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        SERVICE_NAME=$(yq eval ".services[$i].name" "$CONFIG_FILE")
        SERVICE_DOMAIN=$(yq eval ".services[$i].domain // \"\"" "$CONFIG_FILE")
        ENABLED=$(yq eval ".services[$i].enabled // true" "$CONFIG_FILE")
        ICON=$(yq eval ".services[$i].icon // \"\"" "$CONFIG_FILE")
        
        if [ "$ENABLED" = "true" ] && [ -n "$SERVICE_DOMAIN" ]; then
            cat >> "$GLANCE_CONFIG" << EOF
              - title: $SERVICE_NAME
                url: https://$SERVICE_DOMAIN
EOF
            if [ -n "$ICON" ]; then
                echo "                icon: $ICON" >> "$GLANCE_CONFIG"
            fi
        fi
    done
    
    echo "✓ Glance: Created minimal config at: $GLANCE_CONFIG"
fi

# Generate docker-compose for Glance
echo ""
echo "Generating Glance docker-compose..."
cat > "$GLANCE_OUTPUT_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  glance:
    image: glanceapp/glance:latest
    container_name: glance
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./glance.yml:/app/config/glance.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TZ=${TIMEZONE}
    networks:
      - caddy_network

networks:
  caddy_network:
    external: true
EOF

echo "✓ Glance docker-compose generated"

echo ""
echo "========================================="
echo "Configuration Generation Complete!"
echo "========================================="
echo ""
echo "Generated files:"
echo "  • Caddyfile: $CADDYFILE"
echo "  • Glance config: $GLANCE_CONFIG"
echo "  • Glance compose: $GLANCE_OUTPUT_DIR/docker-compose.yml"
