#!/bin/bash

#############################################
# COMPLETE DOCKER INFRASTRUCTURE SETUP
# Configure Firewall
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
# 3: Configure Firewall
#############################################
print_header " 3: Configure Firewall"

echo "Starting firewall service..."
sudo systemctl start firewalld
sudo systemctl enable firewalld
print_success "Firewall service enabled"

echo "Adding firewall rules..."

# HTTP & HTTPS (Nginx Proxy Manager)
sudo firewall-cmd --add-port=80/tcp --permanent
sudo firewall-cmd --add-port=443/tcp --permanent
sudo firewall-cmd --add-port=81/tcp --permanent
print_success "Added HTTP/HTTPS ports (80, 443, 81)"

# Email Ports
sudo firewall-cmd --add-port=25/tcp --permanent    # SMTP
sudo firewall-cmd --add-port=465/tcp --permanent   # SMTPS
sudo firewall-cmd --add-port=587/tcp --permanent   # Submission
sudo firewall-cmd --add-port=143/tcp --permanent   # IMAP
sudo firewall-cmd --add-port=993/tcp --permanent   # IMAPS
sudo firewall-cmd --add-port=110/tcp --permanent   # POP3
sudo firewall-cmd --add-port=995/tcp --permanent   # POP3S
print_success "Added Email ports (25, 465, 587, 143, 993, 110, 995)"

echo "Reloading firewall..."
sudo firewall-cmd --reload
print_success "Firewall configured and reloaded"
confirm_reboot
