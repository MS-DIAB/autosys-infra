#!/bin/bash

#############################################
# Docker Container Management UI
# PORTAINER SETUP - UPDATED FOR AUTOSYS
# Part of AutoSys Infrastructure
#############################################

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PORTAINER_DOMAIN="${PORTAINER_DOMAIN:-portainer.${BASE_DOMAIN:-example.com}}"
PORTAINER_DIR="/opt/portainer"
PORTAINER_DATA_DIR="${PORTAINER_DIR}/data"
PORTAINER_HTTP_PORT="9222"
PORTAINER_HTTPS_PORT="9443"
DOCKER_NETWORK="proxy-network"
TIMEZONE="${TIMEZONE:-UTC}"

print_header() {
  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; exit 1; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || print_error "Required command not found: $1"
}

print_header "8: Setup PORTAINER (Updated)"

print_header "STEP 0: Pre-flight Checks"
require_cmd docker
if ! docker info >/dev/null 2>&1; then
  print_error "Docker is not running or current user cannot access Docker."
fi
if ! docker compose version >/dev/null 2>&1; then
  print_error "Docker Compose plugin is not available."
fi
if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then
  print_error "Docker network '${DOCKER_NETWORK}' does not exist. Run the NPM/network setup first."
fi
print_success "Docker, Docker Compose, and ${DOCKER_NETWORK} are ready"

print_header "STEP 1: Create Directory Structure"
sudo mkdir -p "${PORTAINER_DATA_DIR}" "${PORTAINER_DIR}/backups"
sudo chown -R "$USER:$USER" "${PORTAINER_DIR}"
print_success "Directories created at ${PORTAINER_DIR}"

print_header "STEP 2: Create Environment File"
cat > "${PORTAINER_DIR}/.env" <<EOF_ENV
PORTAINER_DOMAIN=${PORTAINER_DOMAIN}
PORTAINER_HTTP_PORT=${PORTAINER_HTTP_PORT}
PORTAINER_HTTPS_PORT=${PORTAINER_HTTPS_PORT}
TIMEZONE=${TIMEZONE}
DOCKER_NETWORK=${DOCKER_NETWORK}
EOF_ENV
chmod 600 "${PORTAINER_DIR}/.env"
print_success ".env file created"

print_header "STEP 3: Create Docker Compose Configuration"
cat > "${PORTAINER_DIR}/docker-compose.yml" <<'EOF_COMPOSE'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    hostname: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: ${TIMEZONE}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "${PORTAINER_HTTP_PORT}:9000"
      - "${PORTAINER_HTTPS_PORT}:9443"
    networks:
      - proxy-network
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1:9000/api/system/status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

networks:
  proxy-network:
    external: true
    name: ${DOCKER_NETWORK}
EOF_COMPOSE
print_success "docker-compose.yml created"

print_header "STEP 4: Validate and Start Container"
cd "${PORTAINER_DIR}"
docker compose config -q || print_error "Docker Compose configuration is invalid"
docker compose up -d
sleep 15
if ! docker ps --format '{{.Names}}' | grep -qx portainer; then
  docker compose logs --tail 60 portainer || true
  print_error "Portainer container failed to start"
fi
print_success "Portainer container is running"

print_header "STEP 5: Create Helper Scripts"
cat > "${PORTAINER_DIR}/backup.sh" <<'EOF_BACKUP'
#!/bin/bash
set -Eeuo pipefail
BACKUP_DIR="/opt/portainer/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/portainer_backup_${TIMESTAMP}.tar.gz"
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_FILE" -C /opt/portainer data/
echo "Backup created: $BACKUP_FILE"
ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -5 || true
EOF_BACKUP
chmod +x "${PORTAINER_DIR}/backup.sh"

cat > "${PORTAINER_DIR}/restore.sh" <<'EOF_RESTORE'
#!/bin/bash
set -Eeuo pipefail
if [ $# -lt 1 ]; then
  echo "Usage: $0 /opt/portainer/backups/portainer_backup_YYYYMMDD_HHMMSS.tar.gz"
  exit 1
fi
BACKUP_FILE="$1"
[ -f "$BACKUP_FILE" ] || { echo "Backup file not found: $BACKUP_FILE"; exit 1; }
echo "WARNING: This will stop Portainer and overwrite existing data."
read -r -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Cancelled."; exit 0; }
cd /opt/portainer
docker compose down
rm -rf /opt/portainer/data/*
tar -xzf "$BACKUP_FILE" -C /opt/portainer/
docker compose up -d
echo "Restore complete."
EOF_RESTORE
chmod +x "${PORTAINER_DIR}/restore.sh"

cat > "${PORTAINER_DIR}/reset-password.sh" <<'EOF_RESET'
#!/bin/bash
set -Eeuo pipefail
echo "WARNING: This will reset Portainer admin credentials."
read -r -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Cancelled."; exit 0; }
cd /opt/portainer
docker compose down
rm -f /opt/portainer/data/portainer.db
docker compose up -d
echo "Password reset complete. Visit Portainer and create a new admin account."
EOF_RESET
chmod +x "${PORTAINER_DIR}/reset-password.sh"
print_success "Helper scripts created"

print_header "STEP 6: Connection Information"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Direct HTTP:  http://${SERVER_IP}:${PORTAINER_HTTP_PORT}"
echo "Direct HTTPS: https://${SERVER_IP}:${PORTAINER_HTTPS_PORT}"
echo "Via NPM:      https://${PORTAINER_DOMAIN}"
print_warning "Create the Portainer admin account within 5 minutes of first launch."
print_warning "If the initial setup window expires, run: ${PORTAINER_DIR}/reset-password.sh"

print_header "STEP 7: Nginx Proxy Manager Configuration"
echo "Domain: ${PORTAINER_DOMAIN}"
echo "Forward Hostname/IP: portainer"
echo "Forward Port: 9000"
echo "Scheme: http"
echo "Enable Block Common Exploits, Websockets Support, Force SSL, HTTP/2, HSTS"

echo
print_success "Portainer setup completed successfully"
