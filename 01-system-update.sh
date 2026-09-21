#!/bin/bash

#############################################
# COMPLETE DOCKER INFRASTRUCTURE SETUP
# Update System & Install Tools
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
# 1: Update System & Install Tools
#############################################
print_header " 1: System Update & Tools Installation"

echo "Updating system packages..."
sudo dnf update -y && sudo dnf upgrade -y
print_success "System updated"

echo "Installing essential tools..."
sudo dnf install -y curl wget nano git unzip tar net-tools
print_success "Tools installed"

#############################################
# 2: Configure Timezone
#############################################
TIMEZONE="${TIMEZONE:-UTC}"
print_header " 2: Configure Timezone (${TIMEZONE})"

echo "Setting timezone to ${TIMEZONE}..."
sudo timedatectl set-timezone "${TIMEZONE}"
sudo timedatectl set-ntp true

CURRENT_TZ=$(timedatectl | grep "Time zone")
echo "Current timezone: $CURRENT_TZ"
print_success "Timezone configured"

confirm_reboot

