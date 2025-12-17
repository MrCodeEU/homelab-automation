#!/bin/bash
# Configuration generator script
# Reads services.yml and generates Caddyfile, Glance config, and docker-compose configurations

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    # Fallback
    echo "Warning: common.sh not found"
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_header() { echo "=== $1 ==="; }
    set_error_trap() { set -e; }
fi

set_error_trap

log_header "Generating Configurations from YAML"

CONFIG_FILE="${1:-/tmp/homelab-deploy/configs/services.yml}"
CADDY_OUTPUT_DIR="${2:-/opt/caddy}"
GLANCE_OUTPUT_DIR="${3:-/opt/glance}"
INVENTORY_FILE="${4:-/tmp/homelab-deploy/inventory.yml}"

log_info "Config file: $CONFIG_FILE"
log_info "Caddy output: $CADDY_OUTPUT_DIR"
log_info "Glance output: $GLANCE_OUTPUT_DIR"
log_info "Inventory file: $INVENTORY_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_info "Looking for file..."
    ls -la "$(dirname "$CONFIG_FILE")" || log_warn "Directory doesn't exist"
    exit 1
fi

log_success "Configuration file found"

# Check if yq is available
if ! command -v yq &> /dev/null; then
    log_info "Installing yq for YAML parsing..."
    if command -v wget &> /dev/null; then
        wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        chmod +x /usr/local/bin/yq
    else
        log_error "wget not found, cannot install yq. Please install yq manually."
        exit 1
    fi
fi

log_info "Reading configuration from: $CONFIG_FILE"
mkdir -p "$CADDY_OUTPUT_DIR"
mkdir -p "$GLANCE_OUTPUT_DIR"

# Extract global configuration
DOMAIN=$(yq eval '.global.domain // "example.com"' "$CONFIG_FILE")
EMAIL=$(yq eval '.global.email // "admin@example.com"' "$CONFIG_FILE")
LOCATION=$(yq eval '.global.location // "London, United Kingdom"' "$CONFIG_FILE")
DASHBOARD_NAME=$(yq eval '.dashboard.name // "Homelab Dashboard"' "$CONFIG_FILE")
TIMEZONE=$(yq eval '.dashboard.timezone // "Europe/London"' "$CONFIG_FILE")

# Generate Caddyfile
log_info "Generating Caddyfile..."
CADDYFILE="$CADDY_OUTPUT_DIR/Caddyfile"

# Start Caddyfile
cat > "$CADDYFILE" << EOF
# Auto-generated Caddyfile
# Generated from services.yml
# Email for Let's Encrypt: $EMAIL

{
    email $EMAIL
}

# Default route for base domain
$DOMAIN {
    root * /opt/caddy/site
    file_server
    log {
        output file /opt/caddy/logs/access.log
        format json
    }
}

EOF

# Generate default index.html
mkdir -p "$CADDY_OUTPUT_DIR/site"
cat > "$CADDY_OUTPUT_DIR/site/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Homelab Automation</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; background: #1a1a1a; color: #e0e0e0; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
        .container { text-align: center; padding: 2rem; border: 1px solid #333; border-radius: 8px; background: #252525; max-width: 800px; width: 90%; }
        h1 { color: #4caf50; margin-bottom: 0.5rem; }
        p { color: #aaa; margin-bottom: 1.5rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; text-align: left; }
        .card { background: #333; padding: 1rem; border-radius: 6px; text-decoration: none; color: inherit; transition: transform 0.2s, background 0.2s; display: block; }
        .card:hover { transform: translateY(-2px); background: #404040; }
        .card h3 { margin: 0 0 0.5rem 0; color: #fff; }
        .card p { margin: 0; font-size: 0.9rem; color: #bbb; }
        .status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; }
        .status.active { background: #4caf50; }
        .status.inactive { background: #f44336; }
        .footer { margin-top: 2rem; font-size: 0.8rem; color: #666; border-top: 1px solid #333; padding-top: 1rem; }
        .deployment-info { text-align: left; background: #111; padding: 1rem; border-radius: 4px; margin-top: 1rem; font-family: monospace; font-size: 0.85rem; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Homelab Services</h1>
        <p>Managed by Homelab Automation</p>
        
        <div class="grid">
EOF

# Add services to index.html
SERVICE_COUNT=$(yq eval '.services | length' "$CONFIG_FILE")
for i in $(seq 0 $((SERVICE_COUNT - 1))); do
    NAME=$(yq eval ".services[$i].name" "$CONFIG_FILE")
    DOMAIN_VAL=$(yq eval ".services[$i].domain" "$CONFIG_FILE")
    DESC=$(yq eval ".services[$i].description" "$CONFIG_FILE")
    ENABLED=$(yq eval ".services[$i].enabled // true" "$CONFIG_FILE")
    MANAGED=$(yq eval ".services[$i].managed // true" "$CONFIG_FILE")
    
    STATUS_CLASS="active"
    STATUS_TEXT="Active"
    
    if [ "$ENABLED" != "true" ]; then
        STATUS_CLASS="inactive"
        STATUS_TEXT="Disabled"
    elif [ "$MANAGED" != "true" ]; then
        STATUS_CLASS="active" # Still active, just externally managed
        STATUS_TEXT="External"
    fi
    
    cat >> "$CADDY_OUTPUT_DIR/site/index.html" << EOF
            <a href="https://$DOMAIN_VAL" class="card" target="_blank">
                <h3><span class="status $STATUS_CLASS"></span>$NAME</h3>
                <p>$DESC</p>
                <p style="font-size: 0.75rem; margin-top: 0.5rem; opacity: 0.7;">$STATUS_TEXT</p>
            </a>
EOF
done

# Close index.html
cat >> "$CADDY_OUTPUT_DIR/site/index.html" << EOF
        </div>

        <div class="deployment-info">
            <strong>Deployment Info:</strong><br>
            Generated: $(date)<br>
            Domain: $DOMAIN<br>
            Location: $LOCATION
            <!-- DEPLOYMENT_STATUS -->
        </div>

        <div class="footer">
            <p>Deployed via GitHub Actions &bull; <a href="https://github.com/mljr/homelab-automation" style="color: #666;">Source</a></p>
        </div>
    </div>
</body>
</html>
EOF

# Parse services and generate Caddy blocks
SERVICE_COUNT=$(yq eval '.services | length' "$CONFIG_FILE")

if [ "$SERVICE_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        SERVICE_NAME=$(yq eval ".services[$i].name" "$CONFIG_FILE")
        DOMAIN=$(yq eval ".services[$i].domain // \"\"" "$CONFIG_FILE")
        PORT=$(yq eval ".services[$i].port // \"\"" "$CONFIG_FILE")
        HOST=$(yq eval ".services[$i].host // \"\"" "$CONFIG_FILE")
        UPSTREAM=$(yq eval ".services[$i].upstream // \"\"" "$CONFIG_FILE")
        ENABLED=$(yq eval ".services[$i].enabled // true" "$CONFIG_FILE")
        SKIP_DEPLOY=$(yq eval ".services[$i].skip_deploy // false" "$CONFIG_FILE")
        
        # Skip if not enabled, explicitly skipped, or no domain
        if [ "$ENABLED" != "true" ] || [ "$SKIP_DEPLOY" = "true" ] || [ -z "$DOMAIN" ]; then
            continue
        fi
        
        # Determine the upstream target
        if [ -n "$UPSTREAM" ]; then
            # Use custom upstream URL
            TARGET="$UPSTREAM"
        elif [ -n "$PORT" ]; then
          # Build target from host:port
          EFFECTIVE_HOST="$HOST"
          
          # Check if host is defined in inventory
          IS_IN_INVENTORY="false"
          if [ -n "$EFFECTIVE_HOST" ] && [ "$EFFECTIVE_HOST" != "localhost" ] && [ "$EFFECTIVE_HOST" != "null" ] && [ -f "$INVENTORY_FILE" ]; then
             IS_IN_INVENTORY=$(yq eval ".devices | has(\"$EFFECTIVE_HOST\")" "$INVENTORY_FILE")
          fi

          if [ "$IS_IN_INVENTORY" = "true" ]; then
             # Get primary hostname
             PRIMARY_HOST=$(yq eval ".devices.$EFFECTIVE_HOST.hostname" "$INVENTORY_FILE")
             TARGET="$PRIMARY_HOST:$PORT"
             
             # Get fallbacks
             FALLBACK_COUNT=$(yq eval ".devices.$EFFECTIVE_HOST.fallbacks | length" "$INVENTORY_FILE")
             if [ "$FALLBACK_COUNT" -gt 0 ] && [ "$FALLBACK_COUNT" != "null" ]; then
                 for j in $(seq 0 $((FALLBACK_COUNT - 1))); do
                     FB_HOST=$(yq eval ".devices.$EFFECTIVE_HOST.fallbacks[$j]" "$INVENTORY_FILE")
                     TARGET="$TARGET $FB_HOST:$PORT"
                 done
             fi
             echo "  - Resolved $EFFECTIVE_HOST to $TARGET"
          elif [ -z "$EFFECTIVE_HOST" ] || [ "$EFFECTIVE_HOST" = "localhost" ] || [ "$EFFECTIVE_HOST" = "null" ]; then
            # Default to localhost since Caddy is running in host mode
            # This REQUIRES the target service to expose its port to the host (e.g. ports: - "8080:8080")
            # Docker internal DNS (e.g. "glance") will NOT work because Caddy is on the host network
            EFFECTIVE_HOST="127.0.0.1"
            TARGET="$EFFECTIVE_HOST:$PORT"
          else
            TARGET="$EFFECTIVE_HOST:$PORT"
          fi
        else
            echo "⚠️  Skipping $SERVICE_NAME: No port or upstream defined"
            continue
        fi
        
        # Add to Caddyfile
        echo "" >> "$CADDYFILE"
        echo "# $SERVICE_NAME" >> "$CADDYFILE"
        echo "$DOMAIN {" >> "$CADDYFILE"
        
        if [ "$SERVICE_NAME" = "goaccess" ]; then
             echo "    root * /opt/goaccess/report" >> "$CADDYFILE"
             echo "    file_server" >> "$CADDYFILE"
        else
             echo "    reverse_proxy $TARGET" >> "$CADDYFILE"
        fi

        echo "    log {" >> "$CADDYFILE"
        echo "        output file /opt/caddy/logs/access.log" >> "$CADDYFILE"
        echo "        format json" >> "$CADDYFILE"
        echo "    }" >> "$CADDYFILE"
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

# Format Caddyfile if docker is available (matches Caddy's fmt warning)
if command -v docker &> /dev/null; then
  echo "Formatting Caddyfile with caddy fmt..."
  docker run --rm -v "$CADDY_OUTPUT_DIR:/etc/caddy" caddy:latest caddy fmt --overwrite /etc/caddy/Caddyfile || echo "⚠️  caddy fmt failed; continuing"
else
  echo "⚠️  Docker not available; skipping caddy fmt"
fi

# Generate Glance configuration
echo ""
log_info "Generating Glance configuration..."
GLANCE_CONFIG="$GLANCE_OUTPUT_DIR/glance.yml"

# Check if template exists
TEMPLATE_PATH="/tmp/homelab-deploy/configs/glance/glance.yml.template"
if [ -f "$TEMPLATE_PATH" ]; then
    # Use template and replace variables
    cat "$TEMPLATE_PATH" | \
        sed "s/\${LOCATION}/$LOCATION/g" | \
        sed "s/\${SERVER_NAME}/$(hostname)/g" | \
        sed "s/\${DASHBOARD_NAME}/$DASHBOARD_NAME/g" > "$GLANCE_CONFIG"
    
    log_success "Glance config generated from template at: $GLANCE_CONFIG"
    
    # Append services to the bookmarks/links section
    # We assume the template ends with "links:" or we need to find where to insert.
    # For simplicity, if using the provided template which ends in "links:", we just append.
    
    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        SERVICE_NAME=$(yq eval ".services[$i].name" "$CONFIG_FILE")
        SERVICE_DOMAIN=$(yq eval ".services[$i].domain // \"\"" "$CONFIG_FILE")
        ENABLED=$(yq eval ".services[$i].enabled // true" "$CONFIG_FILE")
        SKIP_DEPLOY=$(yq eval ".services[$i].skip_deploy // false" "$CONFIG_FILE")
        ICON=$(yq eval ".services[$i].icon // \"\"" "$CONFIG_FILE")
        DESCRIPTION=$(yq eval ".services[$i].description // \"\"" "$CONFIG_FILE")
        
        if [ "$ENABLED" = "true" ] && [ "$SKIP_DEPLOY" != "true" ] && [ -n "$SERVICE_DOMAIN" ]; then
            echo "                  - title: $SERVICE_NAME" >> "$GLANCE_CONFIG"
            echo "                    url: https://$SERVICE_DOMAIN" >> "$GLANCE_CONFIG"
            if [ -n "$ICON" ]; then
                # Convert mdi:icon to proper format if needed, or just pass through
                # Glance supports various icon sets.
                echo "                    icon: $ICON" >> "$GLANCE_CONFIG"
            fi
            if [ -n "$DESCRIPTION" ]; then
                 echo "                    description: $DESCRIPTION" >> "$GLANCE_CONFIG"
            fi
        fi
    done
    
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
        SKIP_DEPLOY=$(yq eval ".services[$i].skip_deploy // false" "$CONFIG_FILE")
        ICON=$(yq eval ".services[$i].icon // \"\"" "$CONFIG_FILE")
        
        if [ "$ENABLED" = "true" ] && [ "$SKIP_DEPLOY" != "true" ] && [ -n "$SERVICE_DOMAIN" ]; then
            cat >> "$GLANCE_CONFIG" << EOF
              - title: $SERVICE_NAME
                url: https://$SERVICE_DOMAIN
EOF
            if [ -n "$ICON" ]; then
                echo "                icon: $ICON" >> "$GLANCE_CONFIG"
            fi
        fi
    done
    
    log_success "Glance: Created minimal config at: $GLANCE_CONFIG"
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
