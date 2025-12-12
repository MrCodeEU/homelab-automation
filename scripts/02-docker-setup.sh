#!/bin/bash
# Docker installation and setup script for Rocky Linux

set -e

echo "========================================="
echo "Starting Docker Installation (Rocky Linux)"
echo "========================================="

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    echo "Docker is already installed: $(docker --version)"
    DOCKER_EXISTS=true
else
    DOCKER_EXISTS=false
fi

# Install Docker if not present
if [ "$DOCKER_EXISTS" = false ]; then
    echo "Installing Docker..."
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "Skipping Docker installation (already installed)"
fi

# Start and enable Docker service
echo "Enabling Docker service..."
systemctl enable docker
systemctl start docker

# Verify Docker installation
echo "Verifying Docker installation..."
docker --version
docker compose version

# Add current user to docker group (if not root)
if [ "$EUID" -ne 0 ] && [ -n "$SUDO_USER" ]; then
    echo "Adding $SUDO_USER to docker group..."
    usermod -aG docker $SUDO_USER
    echo "Note: You may need to log out and back in for group changes to take effect"
fi

# Test Docker
echo "Testing Docker..."
docker run --rm hello-world

echo "========================================="
echo "Docker Installation Complete!"
echo "========================================="
