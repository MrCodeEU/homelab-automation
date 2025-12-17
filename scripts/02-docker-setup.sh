#!/bin/bash
# Docker installation and setup script

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

OS_TYPE="${1:-auto}"

log_header "Starting Docker Installation"

# Detect OS if set to auto
if [ "$OS_TYPE" = "auto" ]; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
    else
        log_error "Could not detect OS type. Please specify manually."
        exit 1
    fi
fi

log_info "Detected/Specified OS: $OS_TYPE"

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    log_info "Docker is already installed: $(docker --version)"
    DOCKER_EXISTS=true
else
    DOCKER_EXISTS=false
fi

if [ "$DOCKER_EXISTS" = false ]; then
    log_info "Installing Docker..."
    
    case "$OS_TYPE" in
        rocky|rhel|centos|fedora)
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        ubuntu|debian)
            # Add Docker's official GPG key:
            apt-get update
            apt-get install -y ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS_TYPE/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            # Add the repository to Apt sources:
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_TYPE \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        slackware)
            log_warn "Slackware/Unraid detected. Docker should be managed by the OS."
            log_warn "Skipping installation."
            ;;
            
        *)
            log_error "Unsupported OS for automatic Docker installation: $OS_TYPE"
            exit 1
            ;;
    esac
else
    log_info "Skipping Docker installation (already installed)"
fi

# Start and enable Docker service (skip for Slackware/Unraid as it's managed by OS)
if [ "$OS_TYPE" != "slackware" ]; then
    log_info "Enabling Docker service..."
    systemctl enable docker
    systemctl start docker
fi

# Verify Docker installation
log_info "Verifying Docker installation..."
docker --version
docker compose version

# Add current user to docker group (if not root)
if [ "$EUID" -ne 0 ] && [ -n "$SUDO_USER" ]; then
    log_info "Adding $SUDO_USER to docker group..."
    usermod -aG docker $SUDO_USER
    log_warn "Note: You may need to log out and back in for group changes to take effect"
fi

# Test Docker
log_info "Testing Docker..."
docker run --rm hello-world

log_success "Docker Installation Complete!"
