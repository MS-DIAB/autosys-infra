#!/bin/bash

#############################################
# COMPLETE DOCKER INFRASTRUCTURE SETUP
# Install Docker Engine
# Part of AutoSys Infrastructure
#############################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

confirm_reboot() {
    if [ "${AUTO_REBOOT:-false}" = "true" ]; then
        print_warning "AUTO_REBOOT=true - rebooting automatically in 10 seconds (Ctrl+C to cancel)..."
        sleep 10
        sudo reboot
        return
    fi
    echo
    read -r -p "This step wants to reboot the server now. Reboot? (y/N): " REBOOT_CONFIRM
    if [[ "${REBOOT_CONFIRM}" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        print_warning "Skipping reboot. Reboot manually before running the next script, or re-run this one."
    fi
}


#############################################
# 4: Install Docker Engine
#############################################
print_header " 4: Install Docker Engine"

echo "Adding Docker repository..."
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
print_success "Docker repository added"

echo "Installing Docker..."
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
print_success "Docker installed"

echo "Starting Docker service..."
sudo systemctl start docker
sudo systemctl enable docker
print_success "Docker service started and enabled"

echo "Docker version:"
docker --version
docker compose version

# Add current user to docker group (optional but useful)
echo "Adding user to docker group..."
sudo usermod -aG docker $USER
print_warning "Please log out and log back in for group changes to take effect, or run: newgrp docker"

confirm_reboot
