#!/bin/bash
# Base system setup script
# Installs essential packages: git, curl, wget, vim, htop, etc.

set -e

echo "========================================="
echo "Starting Base System Setup"
echo "========================================="

# Accept OS as parameter, or detect it
OS_PARAM="${1:-}"

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

# Update package lists
echo "Updating package lists..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt-get update -y
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ] || [ "$OS" = "rocky" ]; then
    yum update -y
elif [ "$OS" = "arch" ]; then
    pacman -Sy
elif [ "$OS" = "slackware" ]; then
    # Unraid/Slackware - skip package manager updates (Unraid manages updates via its own system)
    echo "Slackware detected - skipping package manager updates (Unraid manages updates)"
fi

# Install essential packages
echo "Installing essential packages..."
PACKAGES="git curl wget vim htop net-tools ca-certificates"

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    PACKAGES="$PACKAGES gnupg lsb-release software-properties-common"
    apt-get install -y $PACKAGES
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ] || [ "$OS" = "rocky" ]; then
    yum install -y $PACKAGES
elif [ "$OS" = "arch" ]; then
    pacman -S --noconfirm $PACKAGES
elif [ "$OS" = "slackware" ]; then
    # Unraid/Slackware - most packages are already installed or managed by Unraid
    echo "Slackware/Unraid detected - basic packages should already be available"
    echo "If you need additional packages, install them manually via Unraid plugins"
fi

# Install additional utilities (not for Unraid/Slackware)
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    echo "Installing additional utilities..."
    apt-get install -y \
        build-essential \
        apt-transport-https \
        ufw \
        fail2ban \
        unzip \
        jq
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ] || [ "$OS" = "rocky" ]; then
    echo "Installing additional utilities..."
    yum install -y \
        gcc \
        gcc-c++ \
        make \
        unzip \
        jq
fi

echo "========================================="
echo "Base System Setup Complete!"
echo "========================================="
