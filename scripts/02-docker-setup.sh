#!/bin/bash
# Docker installation and setup script
# Installs Docker and Docker Compose

set -e

echo "========================================="
echo "Starting Docker Installation"
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
    
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        # Add Docker's official GPG key
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up the repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        # Install Docker using convenience script
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh
    fi
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
