#!/bin/bash
# Base system setup script
# Installs essential packages
# Assumes: Tailscale is already installed and connected

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    # Fallback if common.sh is not found (e.g. running directly)
    echo "Warning: common.sh not found"
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_header() { echo "=== $1 ==="; }
    set_error_trap() { set -e; }
fi

set_error_trap

OS_TYPE="${1:-auto}"

log_header "Starting Base System Setup"

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

case "$OS_TYPE" in
    rocky|rhel|centos|fedora)
        log_info "Using yum/dnf package manager..."
        
        log_info "Updating system packages..."
        yum update -y
        
        log_info "Installing essential packages..."
        yum install -y \
            git \
            curl \
            wget \
            vim \
            htop \
            net-tools \
            ca-certificates \
            unzip \
            jq \
            tar \
            python3 \
            python3-pip
        ;;
        
    ubuntu|debian)
        log_info "Using apt package manager..."
        
        log_info "Updating system packages..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get upgrade -y
        
        log_info "Installing essential packages..."
        apt-get install -y \
            git \
            curl \
            wget \
            vim \
            htop \
            net-tools \
            ca-certificates \
            unzip \
            jq \
            tar \
            python3 \
            python3-pip
        ;;
        
    slackware)
        log_info "Slackware detected (Unraid?). Skipping package installation as it requires specific handling."
        log_info "Ensure NerdTools or similar is installed for extra packages."
        ;;
        
    *)
        log_error "Unsupported OS: $OS_TYPE"
        exit 1
        ;;
esac

log_success "Base System Setup Complete!"
