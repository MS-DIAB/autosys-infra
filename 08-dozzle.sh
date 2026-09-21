#!/bin/bash

#############################################
# Real-time Docker Container Log Viewer
# DOZZLE SETUP - UPDATED FOR AUTOSYS
# Part of AutoSys Infrastructure
#############################################

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DOZZLE_DOMAIN="${DOZZLE_DOMAIN:-logs.${BASE_DOMAIN:-example.com}}"
DOZZLE_DIR="/opt/dozzle"
DOZZLE_PORT="9999"
DOCKER_NETWORK="proxy-network"
TIMEZONE="${TIMEZONE:-UTC}"
DOZZLE_AUTH_ENABLED="true"
DOZZLE_USERNAME="${DOZZLE_USERNAME:-admin}"
# Generate a random password unless one was supplied via the DOZZLE_PASSWORD
# environment variable. Never ship a hardcoded default in a public script.
DOZZLE_PASSWORD="${DOZZLE_PASSWORD:-$(openssl rand -base64 18)}"
DOZZLE_ADMIN_EMAIL="${DOZZLE_ADMIN_EMAIL:-admin@${BASE_DOMAIN:-example.com}}"

print_header() {
  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}\n"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; exit 1; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }

install_htpasswd() {
  if command -v htpasswd >/dev/null 2>&1; then
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y httpd-tools
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y httpd-tools
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y apache2-utils
  else
    return 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || print_error "Required command not found: $1"
}

print_header "9: Setup DOZZLE (Updated)"

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
if ! command -v htpasswd >/dev/null 2>&1; then
  print_info "htpasswd not found; attempting to install it"
  install_htpasswd || print_warning "Could not install htpasswd; will fall back to Python"
fi
if ! command -v htpasswd >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  print_error "Neither htpasswd nor python3 is available for password generation"
fi
print_success "Prerequisites are ready"

print_header "STEP 1: Create Directory Structure"
sudo mkdir -p "${DOZZLE_DIR}"
sudo chown -R "$USER:$USER" "${DOZZLE_DIR}"
print_success "Directories created at ${DOZZLE_DIR}"

print_header "STEP 2: Generate Authentication Credentials"
PASSWORD_HASH=""
if command -v htpasswd >/dev/null 2>&1; then
  HTPASSWD_OUTPUT=$(printf '%s' "${DOZZLE_PASSWORD}" | htpasswd -B -i -n "${DOZZLE_USERNAME}" 2>/dev/null || true)
  PASSWORD_HASH=$(printf '%s' "${HTPASSWD_OUTPUT}" | cut -d':' -f2)
fi
if [ -z "${PASSWORD_HASH}" ] && command -v python3 >/dev/null 2>&1; then
  PASSWORD_HASH=$(DOZZLE_PASS="${DOZZLE_PASSWORD}" python3 - <<'PY'
import os
pw = os.environ['DOZZLE_PASS'].encode()
try:
    import bcrypt
    print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
except Exception:
    import crypt
    print(crypt.crypt(os.environ['DOZZLE_PASS'], crypt.mksalt(crypt.METHOD_SHA512)))
PY
)
fi
[ -n "${PASSWORD_HASH}" ] || print_error "Failed to generate password hash"
print_success "Password hash generated"

print_header "STEP 3: Create Dozzle Configuration Files"
cat > "${DOZZLE_DIR}/users.yml" <<EOF_USERS
users:
  ${DOZZLE_USERNAME}:
    name: "Administrator"
    password: "${PASSWORD_HASH}"
    email: "${DOZZLE_ADMIN_EMAIL}"
EOF_USERS
chmod 600 "${DOZZLE_DIR}/users.yml"

cat > "${DOZZLE_DIR}/dozzle.yml" <<'EOF_DOZZLECFG'
tailSize: 300
noAnalytics: true
level: info
EOF_DOZZLECFG
print_success "users.yml and dozzle.yml created"

print_header "STEP 4: Create Environment File"
cat > "${DOZZLE_DIR}/.env" <<EOF_ENV
DOZZLE_DOMAIN=${DOZZLE_DOMAIN}
DOZZLE_PORT=${DOZZLE_PORT}
DOCKER_NETWORK=${DOCKER_NETWORK}
TIMEZONE=${TIMEZONE}
DOZZLE_AUTH_ENABLED=${DOZZLE_AUTH_ENABLED}
DOZZLE_USERNAME=${DOZZLE_USERNAME}
DOZZLE_PASSWORD=${DOZZLE_PASSWORD}
EOF_ENV
chmod 600 "${DOZZLE_DIR}/.env"
print_success ".env file created"

print_header "STEP 5: Create Docker Compose Configuration"
cat > "${DOZZLE_DIR}/docker-compose.yml" <<'EOF_COMPOSE'
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    hostname: dozzle
    restart: unless-stopped
    environment:
      DOZZLE_AUTH_PROVIDER: simple
      DOZZLE_LEVEL: info
      DOZZLE_NO_ANALYTICS: "true"
      TZ: ${TIMEZONE}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./users.yml:/data/users.yml:ro
      - ./dozzle.yml:/data/dozzle.yml:ro
    ports:
      - "${DOZZLE_PORT}:8080"
    networks:
      - proxy-network
    healthcheck:
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 15s

networks:
  proxy-network:
    external: true
    name: ${DOCKER_NETWORK}
EOF_COMPOSE
print_success "docker-compose.yml created"

print_header "STEP 6: Validate and Start Container"
cd "${DOZZLE_DIR}"
docker compose config -q || print_error "Docker Compose configuration is invalid"
docker compose up -d
sleep 10
if ! docker ps --format '{{.Names}}' | grep -qx dozzle; then
  docker compose logs --tail 60 dozzle || true
  print_error "Dozzle container failed to start"
fi
print_success "Dozzle container is running"

print_header "STEP 7: Create Helper Scripts"
cat > "${DOZZLE_DIR}/add-user.sh" <<'EOF_ADD'
#!/bin/bash
set -Eeuo pipefail
if [ $# -lt 4 ]; then
  echo "Usage: $0 <username> <password> <full_name> <email>"
  exit 1
fi
USERNAME="$1"
PASSWORD="$2"
NAME="$3"
EMAIL="$4"
if command -v htpasswd >/dev/null 2>&1; then
  HTPASSWD_OUTPUT=$(printf '%s' "$PASSWORD" | htpasswd -B -i -n "$USERNAME" 2>/dev/null)
  PASSWORD_HASH=$(printf '%s' "$HTPASSWD_OUTPUT" | cut -d':' -f2)
else
  PASSWORD_HASH=$(DOZZLE_PASS="$PASSWORD" python3 - <<'PY'
import os, bcrypt
print(bcrypt.hashpw(os.environ['DOZZLE_PASS'].encode(), bcrypt.gensalt()).decode())
PY
)
fi
cat >> /opt/dozzle/users.yml <<EOF_USER
  ${USERNAME}:
    name: "${NAME}"
    password: "${PASSWORD_HASH}"
    email: "${EMAIL}"
EOF_USER
echo "User added. Restart Dozzle: cd /opt/dozzle && docker compose restart dozzle"
EOF_ADD
chmod +x "${DOZZLE_DIR}/add-user.sh"

cat > "${DOZZLE_DIR}/change-password.sh" <<'EOF_CHPASS'
#!/bin/bash
set -Eeuo pipefail
if [ $# -lt 2 ]; then
  echo "Usage: $0 <username> <new_password>"
  exit 1
fi
USERNAME="$1"
NEW_PASSWORD="$2"
if command -v htpasswd >/dev/null 2>&1; then
  HTPASSWD_OUTPUT=$(printf '%s' "$NEW_PASSWORD" | htpasswd -B -i -n "$USERNAME" 2>/dev/null)
  NEW_HASH=$(printf '%s' "$HTPASSWD_OUTPUT" | cut -d':' -f2)
else
  NEW_HASH=$(DOZZLE_PASS="$NEW_PASSWORD" python3 - <<'PY'
import os, bcrypt
print(bcrypt.hashpw(os.environ['DOZZLE_PASS'].encode(), bcrypt.gensalt()).decode())
PY
)
fi
echo "Replace the password value for ${USERNAME} in /opt/dozzle/users.yml with:"
echo "$NEW_HASH"
echo "Then restart Dozzle: cd /opt/dozzle && docker compose restart dozzle"
EOF_CHPASS
chmod +x "${DOZZLE_DIR}/change-password.sh"
print_success "Helper scripts created"

print_header "STEP 8: Connection Information"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Direct URL: http://${SERVER_IP}:${DOZZLE_PORT}"
echo "Via NPM:   https://${DOZZLE_DOMAIN}"
echo "Username:  ${DOZZLE_USERNAME}"
echo "Password:  ${DOZZLE_PASSWORD}"
print_warning "Save this password now - it is also stored in ${DOZZLE_DIR}/.env (chmod 600)."

print_header "STEP 9: Nginx Proxy Manager Configuration"
echo "Domain: ${DOZZLE_DOMAIN}"
echo "Forward Hostname/IP: dozzle"
echo "Forward Port: 8080"
echo "Scheme: http"
echo "Enable Block Common Exploits, Websockets Support, Force SSL, HTTP/2, HSTS"

echo
print_success "Dozzle setup completed successfully"
