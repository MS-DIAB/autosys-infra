#!/bin/bash

#############################################
# COMPLETE DOCKER INFRASTRUCTURE SETUP
# S6: Qwen2.5-Coder via llama.cpp + Open WebUI
# Rocky Linux — Part of AutoSys Infrastructure
#############################################

set -Eeuo pipefail
trap 'echo -e "\033[0;31m✗ Script failed at line $LINENO\033[0m"' ERR

# ------------------------------------------------------------
# Colors / helpers (matches S1/S3/S4 style)
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

# ------------------------------------------------------------
# Config — adjust here if needed
# ------------------------------------------------------------
LLAMA_DIR="/opt/llm/llama.cpp"
MODELS_DIR="/opt/llm/models"
LLAMA_PORT=8080
OPENWEBUI_PORT=3000
LLAMA_CTX_SIZE=8192
LLAMA_BATCH_SIZE=512
SYSTEMD_SERVICE="/etc/systemd/system/llama-server.service"
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
MODEL_FILE="Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
OPENWEBUI_DIR="/opt/openwebui"
NETWORK_NAME="proxy-network"

#############################################
# 1: Hardware Detection
#############################################
print_header "1: Hardware Detection"

SOCKETS=$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/ /,"",$2); print $2}')
CORES_PER_SOCKET=$(lscpu | awk -F: '/Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')
TOTAL_THREADS=$(nproc)
HAS_AVX2=$(grep -o 'avx2' /proc/cpuinfo | head -1 || true)
NUMA_NODES=$(lscpu | awk -F: '/NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}')

echo "Sockets: $SOCKETS"
echo "Cores per socket: $CORES_PER_SOCKET"
echo "Total threads (nproc): $TOTAL_THREADS"
echo "NUMA nodes: $NUMA_NODES"
if [ -n "$HAS_AVX2" ]; then
    print_success "AVX2 supported"
else
    print_warning "AVX2 NOT detected — performance will be significantly lower"
fi

# Leave 2 threads free for OS/Docker/NPM/cloudflared
LLAMA_THREADS=$((TOTAL_THREADS - 2))
if [ "$LLAMA_THREADS" -lt 1 ]; then
    LLAMA_THREADS=$TOTAL_THREADS
fi
echo "llama-server will use --threads $LLAMA_THREADS"

USE_NUMA=""
if [ -n "$NUMA_NODES" ] && [ "$NUMA_NODES" -gt 1 ]; then
    print_warning "Multi-NUMA-node system detected — enabling --numa distribute"
    USE_NUMA="--numa distribute"
fi

sleep 2

#############################################
# 2: Build Dependencies
#############################################
print_header "2: Install Build Dependencies"

echo "Installing build tools (cmake, gcc, git, curl)..."
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y cmake git curl wget numactl numactl-libs
print_success "Build dependencies installed"

# ------------------------------------------------------------
# Disk space check — model + build artifacts need real headroom
# ------------------------------------------------------------
REQUIRED_GB=50
AVAILABLE_GB=$(df --output=avail -BG "$(dirname "$MODELS_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9' || df --output=avail -BG / | tail -1 | tr -dc '0-9')
echo "Available disk space: ${AVAILABLE_GB}GB (recommended minimum: ${REQUIRED_GB}GB)"
if [ "$AVAILABLE_GB" -lt "$REQUIRED_GB" ]; then
    print_error "Insufficient disk space. Need ~${REQUIRED_GB}GB free (model ~20GB, build ~3GB, Docker/images ~5GB, headroom). Aborting."
    exit 1
else
    print_success "Sufficient disk space available"
fi

#############################################
# 3: Build llama.cpp
#############################################
print_header "3: Build llama.cpp (native, CPU-optimized)"

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker not found. Run S3_Install Docker Engine.sh first."
    exit 1
fi
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    print_error "Docker network '$NETWORK_NAME' not found. Run S4_Docker Network&Setup Nginx.sh first."
    exit 1
fi
print_success "Docker and $NETWORK_NAME confirmed"

sudo mkdir -p "$LLAMA_DIR"
sudo chown -R "$USER:$USER" "$LLAMA_DIR"

if [ -d "$LLAMA_DIR/.git" ]; then
    echo "llama.cpp already cloned, pulling latest..."
    cd "$LLAMA_DIR"
    git pull
else
    echo "Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
    cd "$LLAMA_DIR"
fi
print_success "Source ready"

echo "Configuring build (GGML_NATIVE=ON for CPU-specific optimizations)..."
cmake -B build -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
print_success "Build configured"

BUILD_JOBS=$((TOTAL_THREADS > 2 ? TOTAL_THREADS - 2 : 1))
echo "Compiling with -j${BUILD_JOBS} (reserving cores for OS/other services)..."
cmake --build build --config Release -j"$BUILD_JOBS"
print_success "llama.cpp built"

if [ ! -f "$LLAMA_DIR/build/bin/llama-server" ]; then
    print_error "llama-server binary not found after build — aborting"
    exit 1
fi
print_success "llama-server binary confirmed"

#############################################
# 4: Download Model
#############################################
print_header "4: Download Qwen2.5-Coder-32B-Instruct (Q4_K_M)"

sudo mkdir -p "$MODELS_DIR"
sudo chown -R "$USER:$USER" "$MODELS_DIR"

if [ -f "$MODELS_DIR/$MODEL_FILE" ]; then
    print_warning "Model already exists, skipping download"
else
    echo "Downloading $MODEL_FILE into $MODELS_DIR (this is ~20GB, will take time)..."
    curl -fL -C - -o "$MODELS_DIR/$MODEL_FILE" "$MODEL_URL"
    if [ ! -s "$MODELS_DIR/$MODEL_FILE" ]; then
        print_error "Download failed or produced an empty file — aborting"
        exit 1
    fi
    print_success "Model downloaded to $MODELS_DIR/$MODEL_FILE"
fi

# ------------------------------------------------------------
# RAM check — model must fully fit in RAM since we force mlock
# ------------------------------------------------------------
MODEL_SIZE_BYTES=$(stat -c%s "$MODELS_DIR/$MODEL_FILE")
MODEL_SIZE_GB=$((MODEL_SIZE_BYTES / 1024 / 1024 / 1024))
TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

echo "Model size: ~${MODEL_SIZE_GB}GB"
echo "Total system RAM: ~${TOTAL_RAM_GB}GB"

if [ "$MODEL_SIZE_GB" -ge "$TOTAL_RAM_GB" ]; then
    print_error "Model size (${MODEL_SIZE_GB}GB) is too close to/exceeds total RAM (${TOTAL_RAM_GB}GB). mlock will fail. Aborting."
    exit 1
else
    print_success "Sufficient RAM to fully lock model in memory"
fi

#############################################
# 5: Benchmark
#############################################
print_header "5: Benchmark Before Committing"

"$LLAMA_DIR/build/bin/llama-bench" \
    -m "$MODELS_DIR/$MODEL_FILE" \
    -p 512 -n 128 -t "$LLAMA_THREADS" \
    --load-mode mlock || print_warning "Benchmark failed — check manually"

print_warning "Review the tokens/sec above before relying on this for interactive use."

#############################################
# 6: llama-server as systemd service
#############################################
print_header "6: Configure llama-server systemd service"

sudo bash -c "cat > '$SYSTEMD_SERVICE'" <<EOF
[Unit]
Description=llama.cpp server - Qwen2.5-Coder
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$LLAMA_DIR/build/bin/llama-server \\
    -m $MODELS_DIR/$MODEL_FILE \\
    --threads $LLAMA_THREADS \\
    --threads-batch $TOTAL_THREADS \\
    --ctx-size $LLAMA_CTX_SIZE \\
    --batch-size $LLAMA_BATCH_SIZE \\
    --host 0.0.0.0 \\
    --port $LLAMA_PORT \\
    --load-mode mlock \\
    $USE_NUMA
LimitMEMLOCK=infinity
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable llama-server
sudo systemctl restart llama-server
print_success "llama-server systemd service started and enabled"

echo "Waiting for llama-server to come up..."
sleep 10

if curl -s "http://localhost:$LLAMA_PORT/v1/models" >/dev/null; then
    print_success "llama-server API responding on port $LLAMA_PORT"
else
    print_error "llama-server API not responding — check: sudo journalctl -u llama-server -f"
fi

#############################################
# 7: Deploy Open WebUI (Docker, joins proxy-network)
#############################################
print_header "7: Deploy Open WebUI"

sudo mkdir -p "$OPENWEBUI_DIR"
sudo chown -R "$USER:$USER" "$OPENWEBUI_DIR"

cat > "$OPENWEBUI_DIR/docker-compose.yml" <<EOF
services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    restart: unless-stopped
    ports:
      - "127.0.0.1:${OPENWEBUI_PORT}:8080"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - OPENAI_API_BASE_URL=http://host.docker.internal:${LLAMA_PORT}/v1
      - OPENAI_API_KEY=sk-none
      - TZ=${TIMEZONE:-UTC}
    volumes:
      - ./data:/app/backend/data
    networks:
      - proxy-network

networks:
  proxy-network:
    external: true
EOF

print_success "Open WebUI docker-compose.yml created"

cd "$OPENWEBUI_DIR"
docker compose up -d
print_success "Open WebUI container started"

echo "Waiting for Open WebUI to initialize..."
sleep 15

if docker ps --format '{{.Names}}' | grep -qx "openwebui"; then
    print_success "Open WebUI is running"
else
    print_error "Open WebUI failed to start — check: docker compose -f $OPENWEBUI_DIR/docker-compose.yml logs"
fi

#############################################
# Summary
#############################################
print_header "Setup Complete"

echo "llama-server:"
echo "  Service: systemctl status llama-server"
echo "  API:     http://localhost:$LLAMA_PORT/v1"
echo "  Logs:    sudo journalctl -u llama-server -f"
echo
echo "Open WebUI:"
echo "  Container: openwebui (on $NETWORK_NAME)"
echo "  Backend:   http://host.docker.internal:${LLAMA_PORT}/v1 (llama-server, reachable from Docker bridge)"
echo "  Local test access: http://127.0.0.1:${OPENWEBUI_PORT}  (SSH tunnel or local browser only)"
echo
print_warning "llama-server listens on 0.0.0.0:${LLAMA_PORT} so Docker containers can reach it via host.docker.internal."
print_warning "Port ${LLAMA_PORT} is NOT opened in firewalld, so it should not be reachable from outside this host — verify with: sudo firewall-cmd --list-ports"
echo
print_warning "Next manual steps (not automated by this script):"
echo "  1. In Nginx Proxy Manager (already running from S4), add a Proxy Host pointing to container 'openwebui' on port 8080 (same $NETWORK_NAME network — no need for the host-mapped port)."
echo "  2. In the Cloudflare Tunnel dashboard, add a Public Hostname pointing to 'http://openwebui:8080' (or via NPM if you prefer a proxy hop)."
echo "  3. Add a Cloudflare Access policy restricting access to your email only."
echo "  4. Create your first admin account in Open WebUI on first visit."
