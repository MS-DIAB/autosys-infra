#!/bin/bash

#############################################
# COMPLETE N8N DOCKER SETUP
# AutoSys Infrastructure
#
# Architecture:
#
# Internet
#    │
#    ▼
# Cloudflare Tunnel
#    │
#    ▼
# Nginx Proxy Manager
#    │
#    ▼
# n8n :5678
#
# Docker Network:
# proxy-network
#############################################

set -e

#############################################
# COLORS
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


#############################################
# CONFIGURATION
#############################################

N8N_DOMAIN="${N8N_DOMAIN:-n8n.${BASE_DOMAIN:-example.com}}"
N8N_TIMEZONE="${TIMEZONE:-UTC}"

N8N_INSTALL_DIR="/opt/n8n"
N8N_DATA_DIR="${N8N_INSTALL_DIR}/data"
BACKUP_DIR="${N8N_INSTALL_DIR}/backups"

N8N_MEMORY_LIMIT="10G"
N8N_CPU_LIMIT="5.0"

DOCKER_NETWORK="proxy-network"

HEALTHCHECK_TIMEOUT=180

ENCRYPTION_KEY_FILE="${N8N_INSTALL_DIR}/.encryption_key"


#############################################
# FUNCTIONS
#############################################

print_header() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
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


#############################################
# STEP 1
# PRE-FLIGHT CHECKS
#############################################

print_header "STEP 1: Pre-flight Checks"

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker is not installed."
    exit 1
fi

print_success "Docker is installed"

if ! docker compose version >/dev/null 2>&1; then
    print_error "Docker Compose v2 is not available."
    exit 1
fi

print_success "Docker Compose is available"


#############################################
# STEP 2
# DOCKER NETWORK
#############################################

print_header "STEP 2: Docker Network"

echo "Checking Docker network: ${DOCKER_NETWORK}"

if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then

    print_warning "Network does not exist. Creating it..."

    docker network create "${DOCKER_NETWORK}"

    print_success "Docker network created"

else

    print_success "Docker network already exists"

fi


#############################################
# STEP 3
# DIRECTORIES
#############################################

print_header "STEP 3: Create n8n Directories"

sudo mkdir -p "${N8N_DATA_DIR}"
sudo mkdir -p "${BACKUP_DIR}"

sudo chown -R 1000:1000 "${N8N_DATA_DIR}"
sudo chown -R 1000:1000 "${BACKUP_DIR}"

print_success "n8n directories created"

echo
echo "Install directory:"
echo "  ${N8N_INSTALL_DIR}"

echo
echo "Data directory:"
echo "  ${N8N_DATA_DIR}"

echo
echo "Backup directory:"
echo "  ${BACKUP_DIR}"


#############################################
# STEP 4
# ENCRYPTION KEY
#############################################

print_header "STEP 4: n8n Encryption Key"

if [ -f "${ENCRYPTION_KEY_FILE}" ]; then

    N8N_ENCRYPTION_KEY=$(sudo cat "${ENCRYPTION_KEY_FILE}")

    if [ -z "${N8N_ENCRYPTION_KEY}" ]; then

        print_error "Encryption key file exists but is empty."

        exit 1

    fi

    print_success "Existing encryption key loaded"

else

    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

    echo "${N8N_ENCRYPTION_KEY}" \
        | sudo tee "${ENCRYPTION_KEY_FILE}" >/dev/null

    sudo chmod 600 "${ENCRYPTION_KEY_FILE}"

    print_success "New encryption key generated"

    print_warning "IMPORTANT:"
    print_warning "Back up this file securely:"
    print_warning "${ENCRYPTION_KEY_FILE}"

fi


#############################################
# STEP 5
# PULL N8N IMAGE
#############################################

print_header "STEP 5: Pull n8n Image"

echo "Pulling latest n8n image..."

docker pull n8nio/n8n:latest

print_success "n8n image pulled"


#############################################
# STEP 6
# CREATE DOCKER COMPOSE
#############################################

print_header "STEP 6: Create docker-compose.yml"

sudo tee "${N8N_INSTALL_DIR}/docker-compose.yml" >/dev/null <<EOF

services:

  n8n:

    image: n8nio/n8n:latest

    container_name: n8n

    restart: unless-stopped

    hostname: n8n


    #########################################
    # ENVIRONMENT
    #########################################

    environment:

      # Public URL
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https

      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}/
      WEBHOOK_URL: https://${N8N_DOMAIN}/


      # Reverse proxy
      N8N_PROXY_HOPS: 1
      N8N_EXPRESS_TRUST_PROXY: true
      N8N_SECURE_COOKIE: true


      # Timezone
      GENERIC_TIMEZONE: ${N8N_TIMEZONE}


      # Execution timeout
      EXECUTIONS_TIMEOUT: 1200000

      N8N_DEFAULT_HTTP_REQUEST_TIMEOUT: 1200000


      # Encryption
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}


      # Community nodes
      N8N_COMMUNITY_PACKAGES_ENABLED: true
      N8N_REINSTALL_MISSING_PACKAGES: true


      # SQLite
      DB_SQLITE_VACUUM_ON_STARTUP: true


      # Execution pruning
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE: 168


      # Runner
      N8N_RUNNERS_DISABLED: true


      # Logging
      N8N_LOG_LEVEL: info
	  
	  #enable the Built-in Execute Command Node
	  NODES_EXCLUDE=[]


    #########################################
    # STORAGE
    #########################################

    volumes:

      - ./data:/home/node/.n8n


    #########################################
    # NETWORK
    #########################################

    networks:

      - ${DOCKER_NETWORK}


    #########################################
    # HEALTHCHECK
    #########################################

    healthcheck:

      test:
        [
          "CMD",
          "wget",
          "--spider",
          "-q",
          "http://127.0.0.1:5678/healthz"
        ]

      interval: 30s

      timeout: 10s

      retries: 5

      start_period: 90s


    #########################################
    # RESOURCE LIMITS
    #########################################

    deploy:

      resources:

        limits:

          memory: ${N8N_MEMORY_LIMIT}

          cpus: "${N8N_CPU_LIMIT}"


#############################################
# NETWORK
#############################################

networks:

  ${DOCKER_NETWORK}:

    external: true

EOF

print_success "docker-compose.yml created"


#############################################
# STEP 7
# START N8N
#############################################

print_header "STEP 7: Start n8n"

cd "${N8N_INSTALL_DIR}"

echo "Starting n8n..."

docker compose up -d

print_success "n8n container started"


#############################################
# STEP 8
# WAIT FOR N8N
#############################################

print_header "STEP 8: Wait for n8n Health"

echo "Waiting for n8n to become healthy..."

elapsed=0
interval=5

while [ "${elapsed}" -lt "${HEALTHCHECK_TIMEOUT}" ]; do

    health=$(
        docker inspect \
        --format='{{.State.Health.Status}}' \
        n8n 2>/dev/null || echo "not_found"
    )

    case "${health}" in

        healthy)

            print_success "n8n is healthy!"

            break

            ;;

        starting)

            echo "n8n is still starting... ${elapsed}s/${HEALTHCHECK_TIMEOUT}s"

            ;;

        unhealthy)

            print_warning "n8n healthcheck currently reports unhealthy..."

            ;;

        not_found)

            print_warning "n8n container not found..."

            ;;

        *)

            echo "Current status: ${health}"

            ;;

    esac

    sleep "${interval}"

    elapsed=$((elapsed + interval))

done


#############################################
# FINAL HEALTH CHECK
#############################################

health=$(
    docker inspect \
    --format='{{.State.Health.Status}}' \
    n8n 2>/dev/null || echo "not_found"
)


if [ "${health}" != "healthy" ]; then

    print_error "n8n did not become healthy."

    echo
    echo "Container status:"
    docker ps -a --filter name=n8n

    echo
    echo "Last n8n logs:"
    docker compose logs --tail=100 n8n

    exit 1

fi

print_success "n8n healthcheck passed"


#############################################
# STEP 9
# NETWORK TEST
#############################################

print_header "STEP 9: Test n8n Network"

echo "Testing n8n from NPM..."

if docker exec npm \
    node -e '
require("http").get(
  "http://n8n:5678/healthz",
  r => {
    console.log("HTTP:", r.statusCode);
    process.exit(r.statusCode === 200 ? 0 : 1);
  }
).on("error", e => {
  console.error("ERROR:", e.message);
  process.exit(1);
});
'
then

    print_success "NPM → n8n connectivity works"

else

    print_error "NPM cannot connect to n8n"

    exit 1

fi


#############################################
# STEP 10
# CREATE BACKUP SCRIPT
#############################################

print_header "STEP 10: Create Backup Script"

sudo tee "${N8N_INSTALL_DIR}/backup.sh" >/dev/null <<'BACKUP_EOF'

#!/bin/bash

#############################################
# n8n SQLite Backup
#############################################

set -e

BACKUP_DIR="/opt/n8n/backups"
DATA_DIR="/opt/n8n/data"

RETENTION_DAYS=14

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

BACKUP_FILE="${BACKUP_DIR}/n8n_backup_${TIMESTAMP}.sqlite"

mkdir -p "${BACKUP_DIR}"


#############################################
# CHECK DATABASE
#############################################

if [ ! -f "${DATA_DIR}/database.sqlite" ]; then

    echo "ERROR: SQLite database not found:"
    echo "${DATA_DIR}/database.sqlite"

    exit 1

fi


#############################################
# SQLITE ONLINE BACKUP
#############################################

if command -v sqlite3 >/dev/null 2>&1; then

    echo "Creating SQLite online backup..."

    sqlite3 \
        "${DATA_DIR}/database.sqlite" \
        ".backup '${BACKUP_FILE}'"

else

    echo "sqlite3 not installed."

    echo "Using Docker n8n container for SQLite backup..."

    docker exec n8n \
        sh -c "sqlite3 /home/node/.n8n/database.sqlite \
        \".backup '/home/node/.n8n/database-backup.sqlite'\"" \
        2>/dev/null || true

    if docker cp \
        n8n:/home/node/.n8n/database-backup.sqlite \
        "${BACKUP_FILE}" 2>/dev/null; then

        docker exec n8n \
            rm -f /home/node/.n8n/database-backup.sqlite

    else

        echo "WARNING: SQLite online backup unavailable."

        echo "Using file copy fallback."

        cp \
            "${DATA_DIR}/database.sqlite" \
            "${BACKUP_FILE}"

    fi

fi


#############################################
# COMPRESS
#############################################

gzip "${BACKUP_FILE}"

echo
echo "Backup completed:"
echo "${BACKUP_FILE}.gz"


#############################################
# DELETE OLD BACKUPS
#############################################

find "${BACKUP_DIR}" \
    -type f \
    -name "n8n_backup_*.sqlite.gz" \
    -mtime +"${RETENTION_DAYS}" \
    -delete

echo
echo "Old backups cleaned."

#############################################
# SHOW BACKUPS
#############################################

echo
echo "Available backups:"

ls -lh "${BACKUP_DIR}" || true

BACKUP_EOF


sudo chmod +x "${N8N_INSTALL_DIR}/backup.sh"

print_success "Backup script created"

echo
echo "Backup command:"
echo
echo "  ${N8N_INSTALL_DIR}/backup.sh"


#############################################
# STEP 11
# TEST BACKUP
#############################################

print_header "STEP 11: Test Backup"

echo "Running backup test..."

if sudo "${N8N_INSTALL_DIR}/backup.sh"; then

    print_success "Backup test completed"

else

    print_warning "Backup test failed."

fi


#############################################
# STEP 12
# CRON
#############################################

print_header "STEP 12: Configure Automatic Backup"

CRON_LINE="0 2 * * * ${N8N_INSTALL_DIR}/backup.sh >> ${BACKUP_DIR}/backup.log 2>&1"

if sudo crontab -l 2>/dev/null | grep -Fq "${N8N_INSTALL_DIR}/backup.sh"; then

    print_success "Backup cron already exists"

else

    (
        sudo crontab -l 2>/dev/null || true
        echo "${CRON_LINE}"
    ) | sudo crontab -

    print_success "Nightly backup cron installed"

fi


#############################################
# STEP 13
# DISPLAY NPM CONFIGURATION
#############################################

print_header "STEP 13: Nginx Proxy Manager Configuration"

echo "Configure the NPM Proxy Host as follows:"
echo

echo "-----------------------------------------"
echo "DOMAIN"
echo "-----------------------------------------"
echo "${N8N_DOMAIN}"
echo

echo "-----------------------------------------"
echo "FORWARD"
echo "-----------------------------------------"
echo "Scheme:              http"
echo "Forward Hostname:    n8n"
echo "Forward Port:        5678"
echo

echo "-----------------------------------------"
echo "OPTIONS"
echo "-----------------------------------------"
echo "Block Common Exploits:  ENABLE"
echo "Websockets Support:     ENABLE"
echo

echo "-----------------------------------------"
echo "SSL"
echo "-----------------------------------------"
echo "Force SSL:              ENABLE"
echo "HTTP/2 Support:         ENABLE"
echo "HSTS Enabled:           ENABLE"
echo "HSTS Subdomains:        ENABLE"
echo


#############################################
# STEP 14
# NPM ADVANCED CONFIG
#############################################

print_header "STEP 14: NPM Advanced Configuration"

echo "Put the following in NPM → Proxy Host → Advanced:"
echo

cat <<'NGINX'

proxy_read_timeout 3600s;
proxy_connect_timeout 3600s;
proxy_send_timeout 3600s;

NGINX


#############################################
# STEP 15
# CLOUDFLARE
#############################################

print_header "STEP 15: Cloudflare Tunnel Configuration"

echo "Cloudflare Tunnel should point to:"
echo

echo "  ${N8N_DOMAIN}"
echo "           ↓"
echo "  http://npm:80"
echo

echo "IMPORTANT:"
echo
echo "Do NOT point the Cloudflare Tunnel directly to:"
echo
echo "  http://n8n:5678"
echo
echo "Keep Cloudflare → NPM → n8n."


#############################################
# STEP 16
# FINAL TESTS
#############################################

print_header "STEP 16: Final Tests"

echo "Container status:"
echo

docker ps \
    --filter name=n8n \
    --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"

echo
echo "n8n health:"

docker inspect \
    --format='{{.State.Health.Status}}' \
    n8n

echo
echo "n8n internal URL test:"

if docker exec n8n \
    wget --spider -q \
    http://127.0.0.1:5678/healthz; then

    print_success "n8n internal health endpoint works"

else

    print_error "n8n internal health endpoint failed"

fi


#############################################
# STEP 17
# SUMMARY
#############################################

print_header "n8n Setup Complete"

echo "Public URL:"
echo
echo "  https://${N8N_DOMAIN}"
echo

echo "Install directory:"
echo
echo "  ${N8N_INSTALL_DIR}"
echo

echo "Data:"
echo
echo "  ${N8N_DATA_DIR}"
echo

echo "Backups:"
echo
echo "  ${BACKUP_DIR}"
echo

echo "Encryption key:"
echo
echo "  ${ENCRYPTION_KEY_FILE}"
echo

echo "Memory limit:"
echo
echo "  ${N8N_MEMORY_LIMIT}"
echo

echo "CPU limit:"
echo
echo "  ${N8N_CPU_LIMIT}"
echo

echo "Docker network:"
echo
echo "  ${DOCKER_NETWORK}"
echo

echo "Architecture:"
echo
echo "  Cloudflare Tunnel"
echo "        ↓"
echo "  NPM :80"
echo "        ↓"
echo "  n8n :5678"
echo

print_success "n8n installation/configuration completed successfully."

echo
echo "Useful commands:"
echo
echo "  cd ${N8N_INSTALL_DIR}"
echo "  docker compose ps"
echo "  docker compose logs -f n8n"
echo "  docker compose restart n8n"
echo "  docker compose pull"
echo "  docker compose up -d"
echo