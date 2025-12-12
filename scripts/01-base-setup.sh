#!/bin/bash
# Base system setup script for Rocky Linux
# Installs essential packages
# Assumes: Tailscale is already installed and connected

set -e

echo "========================================="
echo "Starting Base System Setup (Rocky Linux)"
echo "========================================="

# Update system
echo "Updating system packages..."
yum update -y

# Install essential packages
echo "Installing essential packages..."
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
    tar

echo "========================================="
echo "Base System Setup Complete!"
echo "========================================="
