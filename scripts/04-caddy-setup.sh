#!/bin/bash
# Caddy installation and configuration deployment script

set -e

echo "========================================="
echo "Starting Caddy Setup"
echo "========================================="

# Accept OS as first parameter, Caddyfile as second
OS_PARAM="${1:-}"
CADDYFILE_SOURCE="${2:-}"

if [ -n "$OS_PARAM" ]; then
    OS="$OS_PARAM"
    echo "Using provided OS: $OS"
else
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo "Cannot detect OS"
        exit 1
    fi
    echo "Detected OS: $OS"
fi

# Skip Caddy installation for Unraid/Slackware
if [ "$OS" = "slackware" ]; then
    echo "Unraid/Slackware detected - Caddy should be installed as a Docker container"
    echo "Please use Unraid Community Applications to install Caddy"
    echo "========================================="
    exit 0
fi

# Check if Caddy is already installed
if command -v caddy &> /dev/null; then
    echo "Caddy is already installed: $(caddy version)"
    CADDY_EXISTS=true
else
    CADDY_EXISTS=false
fi

# Install Caddy if not present
if [ "$CADDY_EXISTS" = false ]; then
    echo "Installing Caddy..."
    
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        # Install Caddy from official repository
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -y
        apt-get install -y caddy
        
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ] || [ "$OS" = "rocky" ]; then
        # Install Caddy from official repository for Rocky Linux
        yum install -y yum-plugin-copr
        yum copr enable -y @caddy/caddy
        yum install -y caddy
    fi
else
    echo "Skipping Caddy installation (already installed)"
fi

# Create Caddy config directory
CADDY_CONFIG_DIR="/etc/caddy"
mkdir -p "$CADDY_CONFIG_DIR"

# Deploy Caddyfile if provided (second parameter)
if [ -n "$CADDYFILE_SOURCE" ] && [ -f "$CADDYFILE_SOURCE" ]; then
    echo "Deploying Caddyfile from: $CADDYFILE_SOURCE"
    cp "$CADDYFILE_SOURCE" "$CADDY_CONFIG_DIR/Caddyfile"
    
    # Validate Caddyfile
    echo "Validating Caddyfile..."
    caddy validate --config "$CADDY_CONFIG_DIR/Caddyfile"
    
    # Reload Caddy
    echo "Reloading Caddy..."
    systemctl reload caddy
else
    echo "No Caddyfile provided or file not found, skipping configuration deployment"
    echo "Default Caddyfile location: $CADDY_CONFIG_DIR/Caddyfile"
fi

# Enable and start Caddy service
echo "Enabling Caddy service..."
systemctl enable caddy
systemctl start caddy

# Check Caddy status
echo "Caddy status:"
systemctl status caddy --no-pager || true

echo "========================================="
echo "Caddy Setup Complete!"
echo "========================================="
