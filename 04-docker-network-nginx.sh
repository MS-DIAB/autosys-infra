#!/bin/bash

#############################################
# COMPLETE DOCKER INFRASTRUCTURE SETUP
# Create Docker Network & Setup Nginx Proxy Manager
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
# 5: Create Docker Network
#############################################
print_header " 5: Create Docker Bridge Network"

echo "Creating proxy-network..."
docker network create proxy-network 2>/dev/null || echo "Network already exists"
print_success "Docker network created"

echo "Available networks:"
docker network ls

#############################################
# 6: Setup Nginx Proxy Manager
#############################################
print_header " 6: Setup Nginx Proxy Manager (NPM)"

echo "Creating NPM directories..."
sudo mkdir -p /opt/npm/data /opt/npm/letsencrypt
sudo chown -R $USER:$USER /opt/npm
print_success "NPM directories created"

echo "Creating docker-compose.yml for NPM..."
cat > /opt/npm/docker-compose.yml << 'EOF'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: npm
    restart: unless-stopped
    hostname: npm
    ports:
      - '80:80'      # Public HTTP
      - '81:81'      # Admin UI
      - '443:443'    # Public HTTPS
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - TZ=${TIMEZONE:-UTC}
    networks:
      - proxy-network
    healthcheck:
      test: ["CMD", "/usr/bin/check-health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  proxy-network:
    external: true
EOF

print_success "NPM docker-compose.yml created"

echo "Starting NPM container..."
cd /opt/npm
docker compose up -d
print_success "NPM container started"

echo "Waiting for NPM to initialize (40 seconds)..."
sleep 40
confirm_reboot