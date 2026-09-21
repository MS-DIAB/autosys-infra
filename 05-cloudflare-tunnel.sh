#!/bin/bash

set -e

# ============================================================
# Cloudflare Tunnel Docker Setup
# Rocky Linux / Docker Compose
# ============================================================

INSTALL_DIR="/opt/cloudflared"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
NETWORK_NAME="proxy-network"
CONTAINER_NAME="cloudflared"

print_header() {
    echo
    echo "============================================================"
    echo "        Cloudflare Tunnel Docker Setup"
    echo "============================================================"
    echo
}

print_success() {
    echo
    echo "[SUCCESS] $1"
    echo
}

print_error() {
    echo
    echo "[ERROR] $1"
    echo
    exit 1
}

print_header

# ------------------------------------------------------------
# 1. Check Docker
# ------------------------------------------------------------

echo "[1/8] Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker is not installed."
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running or current user cannot access Docker."
fi

echo "Docker: OK"


# ------------------------------------------------------------
# 2. Check Docker Compose
# ------------------------------------------------------------

echo
echo "[2/8] Checking Docker Compose..."

if ! docker compose version >/dev/null 2>&1; then
    print_error "Docker Compose plugin is not available."
fi

docker compose version
echo "Docker Compose: OK"


# ------------------------------------------------------------
# 3. Check proxy-network
# ------------------------------------------------------------

echo
echo "[3/8] Checking Docker network: $NETWORK_NAME"

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    print_error "Docker network '$NETWORK_NAME' does not exist.

Create it first with:

docker network create $NETWORK_NAME"
fi

echo "Network '$NETWORK_NAME': OK"


# ------------------------------------------------------------
# 4. Ask for Cloudflare Tunnel Token
# ------------------------------------------------------------

echo
echo "[4/8] Cloudflare Tunnel Token"
echo

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "Using TUNNEL_TOKEN from the environment."
else
    echo "Paste your Cloudflare Tunnel token."
    echo "The token will NOT be displayed while typing."
    echo
    read -rsp "Cloudflare Tunnel Token: " TUNNEL_TOKEN
    echo
fi

if [ -z "$TUNNEL_TOKEN" ]; then
    print_error "No Cloudflare Tunnel token was entered."
fi

echo "Token received."


# ------------------------------------------------------------
# 5. Create installation directory
# ------------------------------------------------------------

echo
echo "[5/8] Creating Cloudflare directory..."

sudo mkdir -p "$INSTALL_DIR"

echo "Directory:"
echo "  $INSTALL_DIR"


# ------------------------------------------------------------
# 6. Create protected .env
# ------------------------------------------------------------

echo
echo "[6/8] Creating protected environment file..."

sudo bash -c "cat > '$ENV_FILE'" <<EOF
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF

sudo chmod 600 "$ENV_FILE"

# Remove token from shell variable as soon as possible
unset TUNNEL_TOKEN

echo ".env created:"
echo "  $ENV_FILE"
echo "Permissions:"
ls -l "$ENV_FILE"


# ------------------------------------------------------------
# 7. Create Docker Compose file
# ------------------------------------------------------------

echo
echo "[7/8] Creating Docker Compose configuration..."

sudo tee "$COMPOSE_FILE" >/dev/null <<'EOF'
services:

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped

    command:
      - tunnel
      - --no-autoupdate
      - run
      - --token
      - ${TUNNEL_TOKEN}

    networks:
      - proxy-network

networks:

  proxy-network:
    external: true
EOF

echo "Compose file created:"
echo "  $COMPOSE_FILE"


# ------------------------------------------------------------
# 8. Validate and start
# ------------------------------------------------------------

echo
echo "[8/8] Validating Docker Compose configuration..."

cd "$INSTALL_DIR"

if ! docker compose config -q; then
    print_error "Docker Compose configuration is invalid."
fi

echo "Compose configuration: OK"

echo
echo "Starting Cloudflare Tunnel..."

docker compose up -d

echo
echo "Waiting for cloudflared..."
sleep 5

# ------------------------------------------------------------
# Verify container
# ------------------------------------------------------------

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then

    echo
    echo "Cloudflare container failed to start."
    echo
    echo "Recent logs:"
    docker compose logs --tail 30 cloudflared

    exit 1
fi

print_success "Cloudflare Tunnel container is running."

echo "============================================================"
echo "Cloudflare Tunnel Status"
echo "============================================================"
docker ps --filter "name=$CONTAINER_NAME"

echo
echo "Recent Cloudflare logs:"
echo "------------------------------------------------------------"

docker compose logs --tail 30 cloudflared

echo
echo "============================================================"
echo "Setup completed."
echo "============================================================"
echo
echo "Cloudflare directory:"
echo "  $INSTALL_DIR"
echo
echo "Compose file:"
echo "  $COMPOSE_FILE"
echo
echo "Environment file:"
echo "  $ENV_FILE"
echo
echo "Useful commands:"
echo
echo "  docker compose -f $COMPOSE_FILE ps"
echo "  docker compose -f $COMPOSE_FILE logs -f cloudflared"
echo "  docker compose -f $COMPOSE_FILE restart"
echo
echo "============================================================"