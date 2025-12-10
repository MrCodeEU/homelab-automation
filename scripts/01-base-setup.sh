#!/bin/bash
# Base system setup script
# Installs essential packages: git, curl, wget, vim, htop, etc.

set -e

echo "========================================="
echo "Starting Base System Setup"
echo "========================================="

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS"
    exit 1
fi

echo "Detected OS: $OS"

# Update package lists
echo "Updating package lists..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt-get update -y
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
    yum update -y
elif [ "$OS" = "arch" ]; then
    pacman -Sy
fi

# Install essential packages
echo "Installing essential packages..."
PACKAGES="git curl wget vim htop net-tools ca-certificates gnupg lsb-release software-properties-common"

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt-get install -y $PACKAGES
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
    yum install -y $PACKAGES
elif [ "$OS" = "arch" ]; then
    pacman -S --noconfirm $PACKAGES
fi

# Install additional utilities
echo "Installing additional utilities..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt-get install -y \
        build-essential \
        apt-transport-https \
        ufw \
        fail2ban \
        unzip \
        jq
fi

echo "========================================="
echo "Base System Setup Complete!"
echo "========================================="
