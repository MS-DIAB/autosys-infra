#!/bin/bash
#############################################
# S32_Translate-API-v4.sh
#
# Translation API v4.0 — Internal-Only Clean Installer
# Meta NLLB-200 3.3B Multilingual Translation
#
# Usage:
#   chmod +x S32_Translate-API-v4.sh
#   ./S32_Translate-API-v4.sh
#
# After running, follow the printed next steps.
#############################################
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_header()  { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}========================================${NC}\n"; }
print_success() { echo -e "${GREEN}✔ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }
print_v4()      { echo -e "${MAGENTA}★ [v4] $1${NC}"; }

#############################################
# Configuration — v4 internal-only defaults
#############################################
TRANSLATE_API_DOMAIN="${TRANSLATE_API_DOMAIN:-translate-api.internal.example}"
TRANSLATE_API_DIR="${TRANSLATE_API_DIR:-/opt/translate-api}"
TRANSLATE_API_PORT="5080"

# v4: forced single mode for 24 GB internal deployment
TRANSLATE_MODE="single"

# Security — fresh per run
API_SECRET_KEY="$(openssl rand -hex 32)"
ADMIN_API_KEY="trans_$(openssl rand -hex 24)"
REDIS_PASSWORD="$(openssl rand -hex 16)"

# Model
MODEL_NAME="nllb-200-3.3B"
COMPUTE_TYPE="int8"
DEVICE="cpu"

# v4: fixed conservative resources for 8 vCPU / 24 GB VM
CPU_CORES="$(nproc)"
TOTAL_MEM="$(free -g | awk '/^Mem:/{print $2}')"

CORES_PER_INSTANCE=6
TARGET_API_CPUS="6.0"
MEMORY_LIMIT="14G"
MEMORY_RESERVATION="10G"
INSTANCE_COUNT=1

INTRA_THREADS=6
INTER_THREADS=2
MAX_BATCH_SIZE=32
BEAM_SIZE=4
MAX_INPUT_LENGTH=512
MAX_CHUNK_LENGTH=400
MAX_DECODING_LENGTH=1024
CACHE_TTL_SECONDS=86400

# CORS — internal-only default
ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-https://n8n.internal.example}"

# Rate limiting defaults
RATE_LIMIT_DEFAULT=1000
RATE_LIMIT_WINDOW=3600

# Telegram disabled by default in v4
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Host UID used for bind-mount permissions
HOST_UID="$(id -u)"

#############################################
# Pre-flight Checks
#############################################
print_header "Pre-flight Checks"

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker CLI not found. Install Docker Engine and Docker Compose plugin first."
    exit 1
fi

if ! docker info &>/dev/null; then
    print_error "Docker is not running."
    exit 1
fi
print_success "Docker is running"

if ! docker compose version &>/dev/null; then
    print_error "Docker Compose plugin not found. Install docker-compose-plugin."
    exit 1
fi
print_success "Docker Compose plugin available"

if ! command -v openssl >/dev/null 2>&1; then
    print_error "openssl not found."
    exit 1
fi
print_success "openssl available"

print_info "System: ${TOTAL_MEM}GB RAM / ${CPU_CORES} vCPUs"
print_v4 "TRANSLATE_MODE forced to: ${TRANSLATE_MODE} (${INSTANCE_COUNT} instance)"
print_v4 "CPU cap: ${TARGET_API_CPUS}, memory limit: ${MEMORY_LIMIT}, reservation: ${MEMORY_RESERVATION}"

if [ "$TOTAL_MEM" -lt 16 ]; then
    print_error "Minimum 16GB RAM required even for single-instance mode."
    print_info "The NLLB-200 3.3B INT8 model needs approximately 13GB in memory."
    exit 1
elif [ "$TOTAL_MEM" -lt 24 ]; then
    print_warning "Detected ${TOTAL_MEM}GB RAM. 24GB is the recommended minimum for this v4 profile."
fi

AVAILABLE_DISK="$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')"
if [ -n "$AVAILABLE_DISK" ] && [ "$AVAILABLE_DISK" -lt 30 ]; then
    print_warning "Only ${AVAILABLE_DISK}GB disk available under /opt. Recommend 30GB+ for model, images, logs, and cache."
fi

if command -v ss >/dev/null 2>&1; then
    if ss -tuln 2>/dev/null | grep -q ":${TRANSLATE_API_PORT} "; then
        print_error "Port ${TRANSLATE_API_PORT} already in use."
        exit 1
    fi
    print_success "Port ${TRANSLATE_API_PORT} available"
else
    print_warning "ss command not found; skipping port availability check."
fi

if docker network inspect proxy-network &>/dev/null; then
    print_info "Existing proxy-network detected, but v4 does not require it."
    print_info "This stack uses a private translate-internal Docker network only."
fi

#############################################
# STEP 1: Directory Structure
#############################################
print_header "STEP 1: Directory Structure"

sudo mkdir -p "${TRANSLATE_API_DIR}"/{app/services,app/utils,data,logs,cache,models,nginx}
sudo chown -R "${USER}:${USER}" "${TRANSLATE_API_DIR}"
chmod 750 "${TRANSLATE_API_DIR}"
find "${TRANSLATE_API_DIR}" -type d -exec chmod 750 {} +

print_success "Directories created at ${TRANSLATE_API_DIR}"

#############################################
# STEP 2: Environment File
#############################################
print_header "STEP 2: Environment File"

cat > "${TRANSLATE_API_DIR}/.env" << ENVEOF
# Translation API v4.0 Configuration — Internal-Only Edition
# Generated on $(date)
# Security — DO NOT SHARE

API_SECRET_KEY=${API_SECRET_KEY}
ADMIN_API_KEY=${ADMIN_API_KEY}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Service
TRANSLATE_API_DOMAIN=${TRANSLATE_API_DOMAIN}
TRANSLATE_API_PORT=${TRANSLATE_API_PORT}
TRANSLATE_MODE=${TRANSLATE_MODE}
INSTANCE_COUNT=${INSTANCE_COUNT}
API_VERSION=4.0.0

# Redis internal-only
REDIS_URL=redis://:${REDIS_PASSWORD}@translate-redis:6379/0

# Model
MODEL_NAME=${MODEL_NAME}
MODEL_PATH=/app/models/nllb-200-3.3B-ct2-int8
COMPUTE_TYPE=${COMPUTE_TYPE}
DEVICE=${DEVICE}

# Performance
INTER_THREADS=${INTER_THREADS}
INTRA_THREADS=${INTRA_THREADS}
OMP_NUM_THREADS=${INTRA_THREADS}
MKL_NUM_THREADS=${INTRA_THREADS}
MAX_BATCH_SIZE=${MAX_BATCH_SIZE}
BEAM_SIZE=${BEAM_SIZE}
MAX_INPUT_LENGTH=${MAX_INPUT_LENGTH}
MAX_CHUNK_LENGTH=${MAX_CHUNK_LENGTH}
MAX_DECODING_LENGTH=${MAX_DECODING_LENGTH}
CACHE_TTL_SECONDS=${CACHE_TTL_SECONDS}

# v4 fixed resources
MEMORY_LIMIT=${MEMORY_LIMIT}
MEMORY_RESERVATION=${MEMORY_RESERVATION}
TARGET_API_CPUS=${TARGET_API_CPUS}

# Rate limiting defaults
RATE_LIMIT_DEFAULT=${RATE_LIMIT_DEFAULT}
RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW}

# CORS
ALLOWED_ORIGINS=${ALLOWED_ORIGINS}

# Telegram Alerts disabled by default
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}

# Timezone
TZ=UTC

# Host UID for bind-mount permissions
HOST_UID=${HOST_UID}
ENVEOF

chmod 600 "${TRANSLATE_API_DIR}/.env"
print_success "Environment file created with mode 600"

#############################################
# STEP 3: Docker Compose — v4 internal-only
#############################################
print_header "STEP 3: Docker Compose"

cat > "${TRANSLATE_API_DIR}/docker-compose.yml" << 'COMPOSEEOF'
services:
  #==========================================
  # LOAD BALANCER / EDGE — Nginx
  # v4: localhost bind only
  #==========================================
  translate-nginx:
    image: nginx:1.25-alpine
    container_name: translate-nginx
    restart: unless-stopped
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "127.0.0.1:5080:5080"
    depends_on:
      translate-api-1:
        condition: service_healthy
    networks:
      - translate-internal
    deploy:
      resources:
        limits:
          memory: 128M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:5080/health/live"]
      interval: 15s
      timeout: 5s
      retries: 3

  #==========================================
  # TRANSLATION API — INSTANCE 1
  # v4: 6 CPU cap, 14G limit, 10G reservation
  #==========================================
  translate-api-1:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        HOST_UID: "${HOST_UID:-1000}"
    container_name: translate-api-1
    restart: unless-stopped
    hostname: translate-api-1
    env_file:
      - .env
    environment:
      - OMP_NUM_THREADS=6
      - MKL_NUM_THREADS=6
      - INSTANCE_ID=1
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs/instance-1
      - ./cache:/app/cache
      - ./models:/app/models:ro
    depends_on:
      translate-redis:
        condition: service_healthy
    networks:
      - translate-internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health/ready"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 300s
    deploy:
      resources:
        limits:
          memory: 14G
          cpus: "6.0"
        reservations:
          memory: 10G

  #==========================================
  # REDIS — Authenticated Cache + State
  # v4: internal-only, no host port
  #==========================================
  translate-redis:
    image: redis:7-alpine
    container_name: translate-redis
    restart: unless-stopped
    hostname: translate-redis
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --appendonly yes
      --maxmemory 2gb
      --maxmemory-policy volatile-lru
      --save 900 1
      --save 300 10
    volumes:
      - translate_redis_data:/data
    networks:
      - translate-internal
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 2G

volumes:
  translate_redis_data:

networks:
  translate-internal:
    driver: bridge
COMPOSEEOF

print_success "docker-compose.yml created"
print_v4 "Nginx bound to 127.0.0.1:5080 only"
print_v4 "Redis has no host-published port"

#############################################
# STEP 4: Nginx Configuration
#############################################
print_header "STEP 4: Nginx Configuration"

cat > "${TRANSLATE_API_DIR}/nginx/nginx.conf" << 'NGINXEOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/json;

    log_format json_combined escape=json
        '{"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_addr":"$upstream_addr",'
        '"upstream_response_time":"$upstream_response_time"}';

    access_log /var/log/nginx/access.log json_combined;

    sendfile on;
    keepalive_timeout 120s;

    client_max_body_size 10M;
    client_body_timeout 120s;

    proxy_read_timeout 120s;
    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;

    gzip on;
    gzip_types application/json text/plain;
    gzip_min_length 1024;

    upstream translate_backend {
        least_conn;
        keepalive 32;
        server translate-api-1:8000 max_fails=3 fail_timeout=30s;
    }

    server {
        listen 5080;
        server_name _;

        # Nginx-only liveness endpoint
        location = /health/live {
            access_log off;
            return 200 '{"alive":true,"proxy":"nginx"}';
            add_header Content-Type application/json;
        }

        # Internal metrics/status only
        location /nginx_status {
            stub_status on;
            access_log off;
            allow 172.16.0.0/12;
            deny all;
        }

        location / {
            proxy_pass         http://translate_backend;
            proxy_http_version 1.1;
            proxy_set_header   Connection "";
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;

            add_header X-Served-By $upstream_addr always;
            add_header X-API-Version "4.0.0" always;
        }
    }
}
NGINXEOF

print_success "Nginx config created"

#############################################
# STEP 5: Dockerfile
#############################################
print_header "STEP 5: Dockerfile"

cat > "${TRANSLATE_API_DIR}/Dockerfile" << 'DOCKEREOF'
# Translation API v4.0 — Multi-stage build
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    patchelf \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Fix CTranslate2 "cannot enable executable stack" error on restricted kernels/LXC
RUN find /opt/venv -type f -name "*.so*" -exec patchelf --clear-execstack {} +

# Pre-download FastText language identification model at build time
RUN python -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='facebook/fasttext-language-identification', filename='model.bin', cache_dir='/opt/fasttext-cache')"

# Runtime stage
FROM python:3.11-slim AS runtime

ARG HOST_UID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r appuser \
    && if getent passwd "${HOST_UID}" >/dev/null; then \
         useradd -r -g appuser -o -u "${HOST_UID}" appuser; \
       else \
         useradd -r -g appuser -u "${HOST_UID}" appuser; \
       fi

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY --from=builder /opt/fasttext-cache /home/appuser/.cache/huggingface

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CT2_VERBOSE=1 \
    HF_HOME=/home/appuser/.cache/huggingface

WORKDIR /app

COPY --chown=appuser:appuser app/ /app/

RUN mkdir -p /app/data /app/logs /app/cache /app/models /home/appuser/.cache && \
    chown -R appuser:appuser /app /home/appuser

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
  CMD curl -f http://localhost:8000/health/ready || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
DOCKEREOF

print_success "Dockerfile created (with UID collision fix + patchelf)"

#############################################
# STEP 6: Requirements
#############################################
print_header "STEP 6: Requirements"

cat > "${TRANSLATE_API_DIR}/requirements.txt" << 'REQEOF'
# Web framework
fastapi==0.110.0
uvicorn[standard]==0.27.1
python-multipart==0.0.9

# Translation engine
ctranslate2==4.0.0
transformers==4.37.2
sentencepiece==0.2.0
protobuf==4.25.3

# Language detection
numpy==1.26.4
fasttext-wheel==0.9.2

# Caching + state
redis==5.0.1

# Config + data
pydantic==2.6.1
pydantic-settings==2.2.1
orjson==3.9.15

# Structured logging
structlog==24.1.0

# Utilities
python-dotenv==1.0.1
huggingface-hub==0.20.3
REQEOF

print_success "requirements.txt created"

#############################################
# STEP 7: Package Files
#############################################
print_header "STEP 7: Package Files"

cat > "${TRANSLATE_API_DIR}/app/__init__.py" << 'EOF'
__version__ = "4.0.0"
EOF

cat > "${TRANSLATE_API_DIR}/app/services/__init__.py" << 'EOF'
EOF

cat > "${TRANSLATE_API_DIR}/app/utils/__init__.py" << 'EOF'
EOF

print_success "Package files created"

#############################################
# STEP 8: Configuration Module
#############################################
print_header "STEP 8: Configuration Module"

cat > "${TRANSLATE_API_DIR}/app/config.py" << 'CONFIGEOF'
"""
Application Configuration — pydantic-settings v4.0
All environment variables validated at startup.
"""
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False, protected_namespaces=("settings_",))

    # API version
    api_version: str = Field("4.0.0")

    # Security
    api_secret_key: str = Field(..., description="Secret key for signing")
    admin_api_key: str = Field(..., description="Admin API key")
    redis_password: str = Field("", description="Redis password")

    # Redis
    redis_url: str = Field("redis://translate-redis:6379/0")

    # Model
    model_path: str = Field("/app/models/nllb-200-3.3B-ct2-int8")
    compute_type: str = Field("int8")
    device: str = Field("cpu")

    # Performance
    inter_threads: int = Field(2)
    intra_threads: int = Field(6)
    max_batch_size: int = Field(32)
    beam_size: int = Field(4)
    max_input_length: int = Field(512)
    max_chunk_length: int = Field(400)
    max_decoding_length: int = Field(1024)
    cache_ttl_seconds: int = Field(86400)

    # Rate limiting defaults
    rate_limit_default: int = Field(1000)
    rate_limit_window: int = Field(3600)

    # CORS
    allowed_origins: str = Field("*")

    # Instance
    instance_id: str = Field("0", description="Instance identifier")

    # Translate mode
    translate_mode: str = Field("single")


settings = Settings()
CONFIGEOF

print_success "Config module created (Pydantic v2 compliant)"

#############################################
# STEP 9: Language Codes Module
#############################################
print_header "STEP 9: Language Codes Module"

cat > "${TRANSLATE_API_DIR}/app/utils/languages.py" << 'LANGEOF'
"""
NLLB-200 Flores-200 Language Codes.
Format: {ISO_639-3}_{ISO_15924_Script}
"""
from typing import Optional

FLORES_CODES = {
    "eng_Latn": "English",
    "spa_Latn": "Spanish",
    "fra_Latn": "French",
    "deu_Latn": "German",
    "por_Latn": "Portuguese",
    "ita_Latn": "Italian",
    "nld_Latn": "Dutch",
    "rus_Cyrl": "Russian",
    "zho_Hans": "Chinese (Simplified)",
    "zho_Hant": "Chinese (Traditional)",
    "jpn_Jpan": "Japanese",
    "kor_Hang": "Korean",
    "arb_Arab": "Arabic (Modern Standard)",
    "hin_Deva": "Hindi",
    "ben_Beng": "Bengali",
    "urd_Arab": "Urdu",
    "tur_Latn": "Turkish",
    "vie_Latn": "Vietnamese",
    "tha_Thai": "Thai",
    "pol_Latn": "Polish",
    "ary_Arab": "Moroccan Arabic",
    "arz_Arab": "Egyptian Arabic",
    "acm_Arab": "Iraqi Arabic",
    "acq_Arab": "Ta'izzi-Adeni Arabic",
    "apc_Arab": "South Levantine Arabic",
    "ajp_Arab": "South Levantine Arabic",
    "aeb_Arab": "Tunisian Arabic",
    "tam_Taml": "Tamil",
    "tel_Telu": "Telugu",
    "mar_Deva": "Marathi",
    "guj_Gujr": "Gujarati",
    "kan_Knda": "Kannada",
    "mal_Mlym": "Malayalam",
    "pan_Guru": "Punjabi",
    "ory_Orya": "Odia",
    "asm_Beng": "Assamese",
    "npi_Deva": "Nepali",
    "sin_Sinh": "Sinhala",
    "mya_Mymr": "Burmese",
    "khm_Khmr": "Khmer",
    "lao_Laoo": "Lao",
    "ind_Latn": "Indonesian",
    "msa_Latn": "Malay",
    "tgl_Latn": "Tagalog",
    "ceb_Latn": "Cebuano",
    "jav_Latn": "Javanese",
    "sun_Latn": "Sundanese",
    "ces_Latn": "Czech",
    "slk_Latn": "Slovak",
    "ukr_Cyrl": "Ukrainian",
    "bel_Cyrl": "Belarusian",
    "bul_Cyrl": "Bulgarian",
    "mkd_Cyrl": "Macedonian",
    "srp_Cyrl": "Serbian",
    "hrv_Latn": "Croatian",
    "slv_Latn": "Slovenian",
    "bos_Latn": "Bosnian",
    "ron_Latn": "Romanian",
    "hun_Latn": "Hungarian",
    "fin_Latn": "Finnish",
    "est_Latn": "Estonian",
    "lav_Latn": "Latvian",
    "lit_Latn": "Lithuanian",
    "ell_Grek": "Greek",
    "swe_Latn": "Swedish",
    "dan_Latn": "Danish",
    "nor_Latn": "Norwegian",
    "isl_Latn": "Icelandic",
    "cat_Latn": "Catalan",
    "glg_Latn": "Galician",
    "eus_Latn": "Basque",
    "cym_Latn": "Welsh",
    "gle_Latn": "Irish",
    "mlt_Latn": "Maltese",
    "sqi_Latn": "Albanian",
    "amh_Ethi": "Amharic",
    "hau_Latn": "Hausa",
    "ibo_Latn": "Igbo",
    "yor_Latn": "Yoruba",
    "swa_Latn": "Swahili",
    "zul_Latn": "Zulu",
    "xho_Latn": "Xhosa",
    "afr_Latn": "Afrikaans",
    "som_Latn": "Somali",
    "orm_Latn": "Oromo",
    "kin_Latn": "Kinyarwanda",
    "nya_Latn": "Chichewa",
    "sna_Latn": "Shona",
    "lin_Latn": "Lingala",
    "lug_Latn": "Luganda",
    "wol_Latn": "Wolof",
    "tsn_Latn": "Tswana",
    "tir_Ethi": "Tigrinya",
    "heb_Hebr": "Hebrew",
    "pes_Arab": "Persian",
    "prs_Arab": "Dari",
    "pus_Arab": "Pashto",
    "kur_Arab": "Kurdish (Central)",
    "kmr_Latn": "Kurdish (Northern)",
    "azj_Latn": "Azerbaijani",
    "aze_Latn": "Azerbaijani",
    "uzn_Latn": "Uzbek",
    "kaz_Cyrl": "Kazakh",
    "kir_Cyrl": "Kyrgyz",
    "tgk_Cyrl": "Tajik",
    "tuk_Latn": "Turkmen",
    "tat_Cyrl": "Tatar",
    "mon_Cyrl": "Mongolian",
    "bod_Tibt": "Tibetan",
    "uig_Arab": "Uyghur",
    "mri_Latn": "Maori",
    "haw_Latn": "Hawaiian",
    "smo_Latn": "Samoan",
    "ton_Latn": "Tongan",
    "fij_Latn": "Fijian",
    "kat_Geor": "Georgian",
    "hye_Armn": "Armenian",
    "ltz_Latn": "Luxembourgish",
    "fry_Latn": "Western Frisian",
    "ast_Latn": "Asturian",
    "oci_Latn": "Occitan",
    "scn_Latn": "Sicilian",
    "srd_Latn": "Sardinian",
    "cos_Latn": "Corsican",
    "hat_Latn": "Haitian Creole",
    "pap_Latn": "Papiamento",
    "mai_Deva": "Maithili",
    "bho_Deva": "Bhojpuri",
    "san_Deva": "Sanskrit",
    "kas_Arab": "Kashmiri (Arabic)",
    "kas_Deva": "Kashmiri (Devanagari)",
    "gom_Deva": "Konkani",
    "doi_Deva": "Dogri",
    "ace_Latn": "Acehnese (Latin)",
    "ace_Arab": "Acehnese (Arabic)",
    "ban_Latn": "Balinese",
    "bjn_Latn": "Banjar",
    "min_Latn": "Minangkabau",
    "bug_Latn": "Buginese",
    "war_Latn": "Waray",
    "ilo_Latn": "Ilocano",
    "pag_Latn": "Pangasinan",
    "hil_Latn": "Hiligaynon",
    "vec_Latn": "Venetian",
    "lmo_Latn": "Lombard",
    "nap_Latn": "Neapolitan",
    "nds_Latn": "Low German",
    "sco_Latn": "Scots",
    "gla_Latn": "Scottish Gaelic",
    "bre_Latn": "Breton",
    "fao_Latn": "Faroese",
    "epo_Latn": "Esperanto",
}

RTL_LANGUAGES = {
    "arb_Arab",
    "ary_Arab",
    "arz_Arab",
    "acm_Arab",
    "acq_Arab",
    "apc_Arab",
    "ajp_Arab",
    "aeb_Arab",
    "heb_Hebr",
    "pes_Arab",
    "prs_Arab",
    "pus_Arab",
    "urd_Arab",
    "uig_Arab",
    "kur_Arab",
    "kas_Arab",
    "ace_Arab",
}

LANGUAGE_ALIASES = {
    "en": "eng_Latn",
    "english": "eng_Latn",
    "es": "spa_Latn",
    "spanish": "spa_Latn",
    "fr": "fra_Latn",
    "french": "fra_Latn",
    "de": "deu_Latn",
    "german": "deu_Latn",
    "pt": "por_Latn",
    "portuguese": "por_Latn",
    "it": "ita_Latn",
    "italian": "ita_Latn",
    "nl": "nld_Latn",
    "dutch": "nld_Latn",
    "ru": "rus_Cyrl",
    "russian": "rus_Cyrl",
    "zh": "zho_Hans",
    "zh-cn": "zho_Hans",
    "zh-tw": "zho_Hant",
    "chinese": "zho_Hans",
    "ja": "jpn_Jpan",
    "japanese": "jpn_Jpan",
    "ko": "kor_Hang",
    "korean": "kor_Hang",
    "ar": "arb_Arab",
    "arabic": "arb_Arab",
    "hi": "hin_Deva",
    "hindi": "hin_Deva",
    "tr": "tur_Latn",
    "turkish": "tur_Latn",
    "vi": "vie_Latn",
    "vietnamese": "vie_Latn",
    "th": "tha_Thai",
    "thai": "tha_Thai",
    "pl": "pol_Latn",
    "polish": "pol_Latn",
    "he": "heb_Hebr",
    "hebrew": "heb_Hebr",
    "fa": "pes_Arab",
    "persian": "pes_Arab",
    "farsi": "pes_Arab",
    "id": "ind_Latn",
    "indonesian": "ind_Latn",
    "ms": "msa_Latn",
    "malay": "msa_Latn",
    "bn": "ben_Beng",
    "bengali": "ben_Beng",
    "ur": "urd_Arab",
    "urdu": "urd_Arab",
    "uk": "ukr_Cyrl",
    "ukrainian": "ukr_Cyrl",
    "el": "ell_Grek",
    "greek": "ell_Grek",
    "cs": "ces_Latn",
    "czech": "ces_Latn",
    "ro": "ron_Latn",
    "romanian": "ron_Latn",
    "hu": "hun_Latn",
    "hungarian": "hun_Latn",
    "sv": "swe_Latn",
    "swedish": "swe_Latn",
    "fi": "fin_Latn",
    "finnish": "fin_Latn",
    "da": "dan_Latn",
    "danish": "dan_Latn",
    "no": "nor_Latn",
    "norwegian": "nor_Latn",
    "sw": "swa_Latn",
    "swahili": "swa_Latn",
    "ta": "tam_Taml",
    "tamil": "tam_Taml",
    "am": "amh_Ethi",
    "amharic": "amh_Ethi",
}


def normalize_language_code(code: str) -> Optional[str]:
    """Convert alias or any format to Flores-200 code."""
    if not code:
        return None

    code_lower = code.lower().strip()

    if code_lower in LANGUAGE_ALIASES:
        return LANGUAGE_ALIASES[code_lower]

    if code in FLORES_CODES:
        return code

    for flores_code in FLORES_CODES:
        if flores_code.lower() == code_lower:
            return flores_code

    return None


def is_rtl_language(code: str) -> bool:
    normalized = normalize_language_code(code)
    return normalized in RTL_LANGUAGES if normalized else False


def get_language_name(code: str) -> str:
    normalized = normalize_language_code(code)
    return FLORES_CODES.get(normalized, "Unknown")


def get_all_languages() -> dict:
    return FLORES_CODES.copy()


def validate_language_code(code: str) -> bool:
    return normalize_language_code(code) is not None
LANGEOF

print_success "Language codes module created"

#############################################
# STEP 10: Translation Service
#############################################
print_header "STEP 10: Translation Service"

cat > "${TRANSLATE_API_DIR}/app/services/translator.py" << 'TRANSEOF'
"""
Translation Service — CTranslate2 NLLB-200 Wrapper.
Includes automatic sentence-boundary chunking.
"""
import os
import re
import asyncio
import logging
from typing import List
from pathlib import Path

import ctranslate2
import sentencepiece as spm

logger = logging.getLogger(__name__)


def _split_into_chunks(text: str, max_chars: int) -> List[str]:
    """
    Split text into chunks <= max_chars, preferring sentence boundaries.
    Falls back to word boundaries, then hard split.
    """
    if len(text) <= max_chars:
        return [text]

    sentence_endings = re.compile(r'(?<=[.!?؟。！？])\s+')
    sentences = sentence_endings.split(text)

    chunks = []
    current = ""

    for sentence in sentences:
        if not sentence.strip():
            continue

        candidate = (current + " " + sentence).strip() if current else sentence

        if len(candidate) <= max_chars:
            current = candidate
        else:
            if current:
                chunks.append(current.strip())

            if len(sentence) > max_chars:
                words = sentence.split()
                word_chunk = ""

                for word in words:
                    candidate_w = (word_chunk + " " + word).strip() if word_chunk else word

                    if len(candidate_w) <= max_chars:
                        word_chunk = candidate_w
                    else:
                        if word_chunk:
                            chunks.append(word_chunk)
                        word_chunk = word[:max_chars]

                if word_chunk:
                    current = word_chunk
                else:
                    current = ""
            else:
                current = sentence

    if current.strip():
        chunks.append(current.strip())

    return chunks if chunks else [text[:max_chars]]


class TranslatorService:
    """NLLB-200 Translation Service — CPU optimized, with auto-chunking."""

    _instance = None
    _lock = None

    def __init__(self):
        self.translator = None
        self.sp_model = None
        self.is_ready = False
        self._init_lock = None

        from config import settings

        self.model_path = settings.model_path
        self.compute_type = settings.compute_type
        self.device = settings.device
        self.inter_threads = settings.inter_threads
        self.intra_threads = settings.intra_threads
        self.beam_size = settings.beam_size
        self.max_input_length = settings.max_input_length
        self.max_chunk_length = settings.max_chunk_length
        self.max_decoding_length = settings.max_decoding_length

    @classmethod
    async def get_instance(cls) -> "TranslatorService":
        if cls._lock is None:
            cls._lock = asyncio.Lock()

        async with cls._lock:
            if cls._instance is None:
                cls._instance = cls()
                await cls._instance.initialize()

        return cls._instance

    async def initialize(self):
        if self._init_lock is None:
            self._init_lock = asyncio.Lock()

        async with self._init_lock:
            if self.is_ready:
                return

            loop = asyncio.get_running_loop()
            await loop.run_in_executor(None, self._load_model)

    def _load_model(self):
        try:
            logger.info(f"Loading NLLB-200 from {self.model_path}")
            logger.info(
                f"device={self.device}, compute={self.compute_type}, "
                f"inter={self.inter_threads}, intra={self.intra_threads}"
            )

            if not Path(self.model_path).exists():
                raise FileNotFoundError(f"Model not found: {self.model_path}")

            self.translator = ctranslate2.Translator(
                self.model_path,
                device=self.device,
                compute_type=self.compute_type,
                inter_threads=self.inter_threads,
                intra_threads=self.intra_threads,
            )

            sp_model_path = os.path.join(self.model_path, "sentencepiece.bpe.model")

            if not os.path.exists(sp_model_path):
                logger.info("Fetching sentencepiece.bpe.model from HuggingFace...")
                from huggingface_hub import hf_hub_download

                sp_model_path = hf_hub_download(
                    repo_id="facebook/nllb-200-3.3B",
                    filename="sentencepiece.bpe.model",
                    local_dir=self.model_path,
                )

            self.sp_model = spm.SentencePieceProcessor()
            self.sp_model.Load(sp_model_path)

            logger.info(f"SentencePiece vocab size: {self.sp_model.GetPieceSize()}")
            self.is_ready = True
            logger.info("NLLB-200 model loaded successfully!")

        except Exception as e:
            logger.error(f"Failed to load model: {e}")
            raise

    def _tokenize(self, text: str, src_lang: str) -> List[str]:
        tokens = self.sp_model.Encode(text, out_type=str)
        return [src_lang] + tokens + ["</s>"]

    def _detokenize(self, tokens: List[str]) -> str:
        special = {"</s>", "<s>", "<pad>", "<unk>"}
        filtered = []

        for t in tokens:
            if t in special:
                continue

            # Skip language tag tokens such as arb_Arab, eng_Latn
            if len(t) >= 8 and "_" in t and t.replace("_", "").replace("-", "").isalpha():
                continue

            filtered.append(t)

        return self.sp_model.Decode(filtered).strip()

    def _translate_single_sync(self, text: str, source_lang: str, target_lang: str) -> str:
        source_tokens = self._tokenize(text, source_lang)

        results = self.translator.translate_batch(
            [source_tokens],
            target_prefix=[[target_lang]],
            beam_size=self.beam_size,
            max_input_length=self.max_input_length,
            max_decoding_length=min(len(source_tokens) * 3, self.max_decoding_length),
            repetition_penalty=1.2,
            no_repeat_ngram_size=3,
        )

        return self._detokenize(results[0].hypotheses[0])

    async def translate(self, text: str, source_lang: str, target_lang: str) -> str:
        if not self.is_ready:
            raise RuntimeError("Translation service not initialized")

        chunks = _split_into_chunks(text, self.max_chunk_length)
        loop = asyncio.get_running_loop()

        if len(chunks) == 1:
            return await loop.run_in_executor(
                None,
                self._translate_single_sync,
                chunks[0],
                source_lang,
                target_lang,
            )

        translated_chunks = []

        for chunk in chunks:
            result = await loop.run_in_executor(
                None,
                self._translate_single_sync,
                chunk,
                source_lang,
                target_lang,
            )
            translated_chunks.append(result)

        return " ".join(translated_chunks)

    async def translate_batch(
        self,
        texts: List[str],
        source_lang: str,
        target_lang: str,
        max_batch_size: int = 32,
    ) -> List[str]:
        if not self.is_ready:
            raise RuntimeError("Translation service not initialized")

        loop = asyncio.get_running_loop()
        results = []

        for i in range(0, len(texts), max_batch_size):
            batch = texts[i:i + max_batch_size]
            batch_results = await loop.run_in_executor(
                None,
                self._translate_batch_sync,
                batch,
                source_lang,
                target_lang,
            )
            results.extend(batch_results)

        return results

    def _translate_batch_sync(
        self,
        texts: List[str],
        source_lang: str,
        target_lang: str,
    ) -> List[str]:
        try:
            sources = [
                self._tokenize(text[:self.max_chunk_length], source_lang)
                for text in texts
            ]

            max_src_len = max(len(s) for s in sources) if sources else 10

            results = self.translator.translate_batch(
                sources,
                target_prefix=[[target_lang]] * len(texts),
                beam_size=self.beam_size,
                max_input_length=self.max_input_length,
                max_decoding_length=min(max_src_len * 3, self.max_decoding_length),
                max_batch_size=len(texts),
                batch_type="examples",
                repetition_penalty=1.2,
                no_repeat_ngram_size=3,
            )

            return [self._detokenize(r.hypotheses[0]) for r in results]

        except Exception as batch_err:
            logger.warning(f"Batch failed, falling back to individual: {batch_err}")
            results = []

            for text in texts:
                try:
                    results.append(
                        self._translate_single_sync(
                            text[:self.max_chunk_length],
                            source_lang,
                            target_lang,
                        )
                    )
                except Exception as e:
                    logger.error(f"Individual translation failed: {e}")
                    results.append("[TRANSLATION_ERROR]")

            return results

    def get_stats(self) -> dict:
        return {
            "is_ready": self.is_ready,
            "model_path": self.model_path,
            "device": self.device,
            "compute_type": self.compute_type,
            "beam_size": self.beam_size,
            "inter_threads": self.inter_threads,
            "intra_threads": self.intra_threads,
            "max_chunk_length": self.max_chunk_length,
        }

    async def cleanup(self):
        if self.translator:
            del self.translator
            self.translator = None

        if self.sp_model:
            del self.sp_model
            self.sp_model = None

        self.is_ready = False
        logger.info("Translation service cleaned up")
TRANSEOF

print_success "Translation service created"

#############################################
# STEP 11: Cache Manager
#############################################
print_header "STEP 11: Cache Manager"

cat > "${TRANSLATE_API_DIR}/app/services/cache.py" << 'CACHEEOF'
"""
Translation Cache Manager — Redis with authentication.
"""
import json
import hashlib
import logging
from typing import Optional, List, Tuple

import redis.asyncio as redis

logger = logging.getLogger(__name__)


class TranslationCache:
    def __init__(self, redis_url: str = None, default_ttl: int = None, key_prefix: str = "trans"):
        from config import settings

        self.redis_url = redis_url or settings.redis_url
        self.default_ttl = default_ttl or settings.cache_ttl_seconds
        self.key_prefix = key_prefix
        self.redis = None

    async def connect(self):
        if self.redis is None:
            self.redis = redis.from_url(
                self.redis_url,
                encoding="utf-8",
                decode_responses=True,
            )

            try:
                await self.redis.ping()
                logger.info("Redis cache connected")
            except Exception as e:
                logger.warning(f"Redis connection failed: {e}")
                self.redis = None

    async def is_connected(self) -> bool:
        if self.redis is None:
            return False

        try:
            await self.redis.ping()
            return True
        except Exception:
            return False

    def _generate_key(self, text: str, source_lang: str, target_lang: str) -> str:
        normalized = " ".join(text.strip().split())
        content = json.dumps(
            {"text": normalized, "src": source_lang.lower(), "tgt": target_lang.lower()},
            sort_keys=True,
        )
        text_hash = hashlib.md5(content.encode()).hexdigest()
        return f"{self.key_prefix}:{source_lang}:{target_lang}:{text_hash}"

    async def get(self, text: str, source_lang: str, target_lang: str) -> Optional[str]:
        if not self.redis:
            return None

        try:
            key = self._generate_key(text, source_lang, target_lang)
            result = await self.redis.get(key)

            if result:
                hits_key = f"{key}:hits"
                hits = await self.redis.incr(hits_key)

                if hits == 1:
                    await self.redis.expire(hits_key, 86400 * 7)

                if hits > 10:
                    await self.redis.expire(key, 86400 * 7)

            return result

        except Exception as e:
            logger.error(f"Cache get failed: {e}")
            return None

    async def set(
        self,
        text: str,
        source_lang: str,
        target_lang: str,
        translation: str,
        ttl: Optional[int] = None,
    ) -> bool:
        if not self.redis:
            return False

        try:
            key = self._generate_key(text, source_lang, target_lang)
            await self.redis.setex(key, ttl or self.default_ttl, translation)
            return True
        except Exception as e:
            logger.error(f"Cache set failed: {e}")
            return False

    async def get_batch(
        self,
        texts: List[str],
        source_lang: str,
        target_lang: str,
    ) -> List[Tuple[int, Optional[str]]]:
        if not self.redis:
            return [(i, None) for i in range(len(texts))]

        try:
            pipe = self.redis.pipeline()
            keys = [self._generate_key(t, source_lang, target_lang) for t in texts]

            for key in keys:
                pipe.get(key)

            cached_values = await pipe.execute()
            return [(i, val) for i, val in enumerate(cached_values)]

        except Exception as e:
            logger.error(f"Batch cache get failed: {e}")
            return [(i, None) for i in range(len(texts))]

    async def set_batch(
        self,
        items: List[Tuple[str, str, str, str]],
        ttl: Optional[int] = None,
    ) -> int:
        if not self.redis:
            return 0

        try:
            pipe = self.redis.pipeline()

            for text, source_lang, target_lang, translation in items:
                key = self._generate_key(text, source_lang, target_lang)
                pipe.setex(key, ttl or self.default_ttl, translation)

            await pipe.execute()
            return len(items)

        except Exception as e:
            logger.error(f"Batch cache set failed: {e}")
            return 0

    async def clear_all(self) -> int:
        if not self.redis:
            return 0

        try:
            keys = []

            async for key in self.redis.scan_iter(f"{self.key_prefix}:*"):
                keys.append(key)

            if keys:
                await self.redis.delete(*keys)

            return len(keys)

        except Exception as e:
            logger.error(f"Cache clear failed: {e}")
            return 0

    async def get_stats(self) -> dict:
        if not self.redis:
            return {"connected": False}

        try:
            info = await self.redis.info("memory")
            keys_count = 0

            async for _ in self.redis.scan_iter(f"{self.key_prefix}:*"):
                keys_count += 1

            return {
                "connected": True,
                "cached_translations": keys_count,
                "memory_used": info.get("used_memory_human", "unknown"),
                "ttl_seconds": self.default_ttl,
            }

        except Exception as e:
            return {"connected": False, "error": str(e)}

    async def close(self):
        if self.redis:
            await self.redis.close()
            self.redis = None
CACHEEOF

print_success "Cache manager created"

#############################################
# STEP 12: Language Detection Service
#############################################
print_header "STEP 12: Language Detection Service"

cat > "${TRANSLATE_API_DIR}/app/services/language_detector.py" << 'LIDEOF'
"""
Language Detection — FastText LID.
Model bundled in Docker image at build time.
"""
import logging
import asyncio
from typing import Tuple, Optional, List

logger = logging.getLogger(__name__)


class LanguageDetector:
    _instance = None

    def __init__(self):
        self.model = None
        self.is_ready = False

    @classmethod
    def get_instance(cls) -> "LanguageDetector":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    async def initialize(self):
        if self.is_ready:
            return

        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._load_model)

    def _load_model(self):
        try:
            import fasttext
            from huggingface_hub import hf_hub_download

            logger.info("Loading FastText language detection model...")

            model_path = hf_hub_download(
                repo_id="facebook/fasttext-language-identification",
                filename="model.bin",
            )

            self.model = fasttext.load_model(model_path)
            self.is_ready = True

            logger.info("Language detection model loaded!")

        except Exception as e:
            logger.warning(f"Failed to load language detection: {e}")

    def detect(self, text: str, top_k: int = 3) -> List[Tuple[str, float]]:
        if not self.is_ready or not self.model:
            return []

        try:
            clean_text = " ".join(text.split())
            predictions = self.model.predict(clean_text, k=top_k)

            return [
                (label.replace("__label__", ""), float(score))
                for label, score in zip(predictions[0], predictions[1])
            ]

        except Exception as e:
            logger.error(f"Language detection failed: {e}")
            return []

    def detect_single(self, text: str) -> Tuple[Optional[str], float]:
        results = self.detect(text, top_k=1)
        return results[0] if results else (None, 0.0)
LIDEOF

print_success "Language detection service created"

#############################################
# STEP 13: Authentication
#############################################
print_header "STEP 13: Authentication"

cat > "${TRANSLATE_API_DIR}/app/utils/auth.py" << 'AUTHEOF'
"""
Authentication — Dynamic API Key Management via Redis.
Supports expiry, char_limit, metadata, and prefix revoke.
"""
import json
import logging
import secrets
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException, Security
from fastapi.security import APIKeyHeader

logger = logging.getLogger(__name__)

API_KEY_HEADER = APIKeyHeader(name="X-API-Key", auto_error=False)

_redis_client = None
_admin_key_info = None


async def init_auth(redis_client, admin_api_key: str):
    global _redis_client, _admin_key_info

    _redis_client = redis_client
    _admin_key_info = {
        "name": "admin",
        "rate_limit": 10000,
        "char_limit": None,
        "permissions": ["read", "write", "admin"],
        "active": True,
        "expires_at": None,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "last_used_at": None,
        "total_chars": 0,
    }

    if redis_client:
        try:
            await _store_admin_key(admin_api_key)
        except Exception as e:
            logger.warning(f"Could not store admin key in Redis: {e}")


async def _store_admin_key(admin_key: str):
    if _redis_client:
        key_data = {
            "name": "admin",
            "rate_limit": 10000,
            "char_limit": None,
            "permissions": ["read", "write", "admin"],
            "active": True,
            "expires_at": None,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "last_used_at": None,
            "total_chars": 0,
        }

        await _redis_client.set(f"apikey:{admin_key}", json.dumps(key_data))
        await _redis_client.set(f"apikey_prefix:{admin_key[:8]}", admin_key)


async def _lookup_key(api_key: str) -> Optional[dict]:
    from config import settings

    if api_key == settings.admin_api_key:
        return _admin_key_info

    if _redis_client:
        try:
            data = await _redis_client.get(f"apikey:{api_key}")

            if data:
                key_info = json.loads(data)

                if not key_info.get("active", True):
                    return None

                expires_at = key_info.get("expires_at")
                if expires_at:
                    try:
                        exp_dt = datetime.fromisoformat(expires_at)
                        if datetime.now(timezone.utc) > exp_dt:
                            logger.info(f"Key expired: {api_key[:8]}...")
                            return None
                    except ValueError:
                        pass

                key_info["last_used_at"] = datetime.now(timezone.utc).isoformat()
                await _redis_client.set(f"apikey:{api_key}", json.dumps(key_info))

                return key_info

        except Exception as e:
            logger.error(f"Redis key lookup failed: {e}")

    return None


async def verify_api_key(api_key: Optional[str] = Security(API_KEY_HEADER)) -> dict:
    if not api_key:
        raise HTTPException(status_code=401, detail="Missing API key. Include X-API-Key header.")

    key_info = await _lookup_key(api_key)

    if key_info:
        return {"api_key": api_key, "api_key_prefix": api_key[:8] + "...", **key_info}

    raise HTTPException(status_code=403, detail="Invalid or expired API key")


async def verify_optional_api_key(
    api_key: Optional[str] = Security(API_KEY_HEADER),
) -> Optional[dict]:
    if not api_key:
        return None

    key_info = await _lookup_key(api_key)

    if key_info:
        return {"api_key": api_key, "api_key_prefix": api_key[:8] + "...", **key_info}

    return None


async def create_api_key(
    api_key: str,
    name: str,
    rate_limit: int = 1000,
    permissions: list = None,
    expires_at: str = None,
    char_limit: int = None,
) -> bool:
    if not _redis_client:
        return False

    try:
        key_data = {
            "name": name,
            "rate_limit": rate_limit,
            "char_limit": char_limit,
            "permissions": permissions or ["read"],
            "active": True,
            "expires_at": expires_at,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "last_used_at": None,
            "total_chars": 0,
        }

        await _redis_client.set(f"apikey:{api_key}", json.dumps(key_data))
        await _redis_client.set(f"apikey_prefix:{api_key[:8]}", api_key)

        logger.info(f"API key created: {name} ({api_key[:8]}...)")
        return True

    except Exception as e:
        logger.error(f"Failed to create API key: {e}")
        return False


async def revoke_api_key(key_or_prefix: str) -> bool:
    if not _redis_client:
        return False

    try:
        full_key = key_or_prefix

        if len(key_or_prefix) == 8:
            stored = await _redis_client.get(f"apikey_prefix:{key_or_prefix}")
            if stored:
                full_key = stored

        result = await _redis_client.delete(f"apikey:{full_key}")
        await _redis_client.delete(f"apikey_prefix:{full_key[:8]}")

        if result:
            logger.info(f"API key revoked: {full_key[:8]}...")

        return bool(result)

    except Exception as e:
        logger.error(f"Failed to revoke API key: {e}")
        return False


async def list_api_keys() -> list:
    if not _redis_client:
        return []

    try:
        keys = []

        async for key in _redis_client.scan_iter("apikey:*"):
            if "_prefix:" in key:
                continue

            data = await _redis_client.get(key)

            if data:
                info = json.loads(data)
                actual_key = key.replace("apikey:", "")

                keys.append({
                    "key_prefix": actual_key[:8] + "...",
                    "name": info.get("name"),
                    "rate_limit": info.get("rate_limit"),
                    "char_limit": info.get("char_limit"),
                    "permissions": info.get("permissions"),
                    "active": info.get("active", True),
                    "expires_at": info.get("expires_at"),
                    "created_at": info.get("created_at"),
                    "last_used_at": info.get("last_used_at"),
                    "total_chars": info.get("total_chars", 0),
                })

        return keys

    except Exception as e:
        logger.error(f"Failed to list API keys: {e}")
        return []
AUTHEOF

print_success "Auth module created"

#############################################
# STEP 14: Rate Limiter
#############################################
print_header "STEP 14: Rate Limiter"

cat > "${TRANSLATE_API_DIR}/app/utils/rate_limiter.py" << 'RATELIMITEOF'
"""
Rate Limiting — Redis-based, per-key limits.
Returns remaining count and reset time for response headers.
"""
import logging
from typing import Optional, Tuple

import redis.asyncio as redis

logger = logging.getLogger(__name__)


class RateLimiter:
    def __init__(self, redis_client: redis.Redis = None):
        self.redis = redis_client

        from config import settings

        self.default_limit = settings.rate_limit_default
        self.window = settings.rate_limit_window
        self._prefix = "translate:ratelimit:"

    async def check_and_get_remaining(
        self,
        key: str,
        limit: Optional[int] = None,
    ) -> Tuple[bool, int, int]:
        if not self.redis:
            return (True, limit or self.default_limit, self.window)

        limit = limit or self.default_limit
        redis_key = f"{self._prefix}{key}"

        try:
            current = await self.redis.incr(redis_key)

            if current == 1:
                await self.redis.expire(redis_key, self.window)

            ttl = await self.redis.ttl(redis_key)
            remaining = max(0, limit - current)
            allowed = current <= limit

            if not allowed:
                logger.warning(f"Rate limit exceeded: {key} ({current}/{limit})")

            return (allowed, remaining, ttl if ttl > 0 else self.window)

        except Exception as e:
            logger.error(f"Rate limit check failed: {e}")
            return (True, self.default_limit, self.window)

    async def check_limit(self, key: str, limit: Optional[int] = None) -> bool:
        allowed, _, _ = await self.check_and_get_remaining(key, limit)
        return allowed
RATELIMITEOF

print_success "Rate limiter created"

#############################################
# STEP 15: Usage Tracker
#############################################
print_header "STEP 15: Usage Tracker"

cat > "${TRANSLATE_API_DIR}/app/utils/usage_tracker.py" << 'USAGEEOF'
"""
Usage Tracker — per-key character counts and request counts in Redis.
Namespace: usage:{key_prefix}:{YYYY-MM}
"""
import json
import logging
from datetime import datetime, timezone
from typing import Optional

import redis.asyncio as aioredis

logger = logging.getLogger(__name__)


class UsageTracker:
    def __init__(self, redis_client: Optional[aioredis.Redis] = None):
        self.redis = redis_client
        self._prefix = "usage"

    def _period_key(self) -> str:
        return datetime.now(timezone.utc).strftime("%Y-%m")

    def _key(self, api_key_prefix: str, metric: str, period: str = None) -> str:
        period = period or self._period_key()
        return f"{self._prefix}:{api_key_prefix}:{period}:{metric}"

    async def record(self, api_key: str, char_count: int, cached: bool = False) -> None:
        if not self.redis:
            return

        prefix = api_key[:8]
        period = self._period_key()

        try:
            pipe = self.redis.pipeline()

            pipe.incrby(self._key(prefix, "chars", period), char_count)
            pipe.incr(self._key(prefix, "requests", period))

            if cached:
                pipe.incr(self._key(prefix, "cached_requests", period))

            ttl = 90 * 86400

            pipe.expire(self._key(prefix, "chars", period), ttl)
            pipe.expire(self._key(prefix, "requests", period), ttl)
            pipe.expire(self._key(prefix, "cached_requests", period), ttl)

            await pipe.execute()

            meta = await self.redis.get(f"apikey:{api_key}")

            if meta:
                key_data = json.loads(meta)
                key_data["total_chars"] = key_data.get("total_chars", 0) + char_count
                await self.redis.set(f"apikey:{api_key}", json.dumps(key_data))

        except Exception as e:
            logger.error(f"Usage record failed: {e}")

    async def get_usage(self, api_key: str, period: str = None) -> dict:
        if not self.redis:
            return {"chars": 0, "requests": 0, "cached_requests": 0}

        prefix = api_key[:8]
        period = period or self._period_key()

        try:
            pipe = self.redis.pipeline()

            pipe.get(self._key(prefix, "chars", period))
            pipe.get(self._key(prefix, "requests", period))
            pipe.get(self._key(prefix, "cached_requests", period))

            results = await pipe.execute()

            return {
                "period": period,
                "chars": int(results[0] or 0),
                "requests": int(results[1] or 0),
                "cached_requests": int(results[2] or 0),
            }

        except Exception as e:
            logger.error(f"Usage get failed: {e}")
            return {"period": period, "chars": 0, "requests": 0, "cached_requests": 0}

    async def check_char_limit(self, api_key: str, char_limit: int) -> bool:
        if not self.redis or not char_limit:
            return True

        usage = await self.get_usage(api_key)
        return usage["chars"] < char_limit

    async def get_platform_stats(self, period: str = None) -> dict:
        if not self.redis:
            return {}

        period = period or self._period_key()

        total_chars = 0
        total_requests = 0
        total_cached = 0

        try:
            async for key in self.redis.scan_iter(f"{self._prefix}:*:{period}:chars"):
                val = await self.redis.get(key)
                total_chars += int(val or 0)

            async for key in self.redis.scan_iter(f"{self._prefix}:*:{period}:requests"):
                val = await self.redis.get(key)
                total_requests += int(val or 0)

            async for key in self.redis.scan_iter(f"{self._prefix}:*:{period}:cached_requests"):
                val = await self.redis.get(key)
                total_cached += int(val or 0)

            return {
                "period": period,
                "total_chars": total_chars,
                "total_requests": total_requests,
                "cached_requests": total_cached,
                "cache_hit_rate": round(total_cached / total_requests, 3) if total_requests else 0,
            }

        except Exception as e:
            logger.error(f"Platform stats failed: {e}")
            return {}
USAGEEOF

print_success "Usage tracker created"

#############################################
# STEP 16: Runtime Config Manager
#############################################
print_header "STEP 16: Runtime Config Manager"

cat > "${TRANSLATE_API_DIR}/app/utils/runtime_config.py" << 'RTCONFIGEOF'
"""
Runtime Configuration Manager.
Allows hot-reload of selected config values without restarting containers.
"""
import json
import logging
from typing import Optional, Any

logger = logging.getLogger(__name__)

_redis_client = None

_CONFIG_KEY = "config:runtime"

ALLOWED_CONFIG_KEYS = {
    "rate_limit_default",
    "rate_limit_window",
    "cache_ttl_seconds",
    "max_batch_size",
    "beam_size",
    "allowed_origins",
}


def init_runtime_config(redis_client):
    global _redis_client
    _redis_client = redis_client


async def get_runtime_config() -> dict:
    if not _redis_client:
        return {}

    try:
        data = await _redis_client.get(_CONFIG_KEY)
        return json.loads(data) if data else {}
    except Exception as e:
        logger.error(f"Runtime config read failed: {e}")
        return {}


async def get_config_value(key: str, default: Any = None) -> Any:
    config = await get_runtime_config()
    return config.get(key, default)


async def update_runtime_config(updates: dict) -> dict:
    if not _redis_client:
        raise RuntimeError("Redis not connected")

    invalid = set(updates.keys()) - ALLOWED_CONFIG_KEYS

    if invalid:
        raise ValueError(f"Unknown config keys: {invalid}. Allowed: {ALLOWED_CONFIG_KEYS}")

    current = await get_runtime_config()
    current.update(updates)

    await _redis_client.set(_CONFIG_KEY, json.dumps(current))
    logger.info(f"Runtime config updated: {list(updates.keys())}")

    return current


async def reset_runtime_config() -> None:
    if _redis_client:
        await _redis_client.delete(_CONFIG_KEY)
        logger.info("Runtime config reset to .env defaults")
RTCONFIGEOF

print_success "Runtime config manager created"

#############################################
# STEP 17: Main Application
#############################################
print_header "STEP 17: Main Application"

cat > "${TRANSLATE_API_DIR}/app/main.py" << 'MAINEOF'
"""
Translation API v4.0 — Meta NLLB-200 3.3B — Internal-Only Edition.
"""
import os
import time
import logging
import secrets
from typing import Optional, List
from datetime import datetime
from contextlib import asynccontextmanager
import asyncio

import structlog
from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks, Request, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field, field_validator

import redis.asyncio as aioredis

from config import settings
from services.translator import TranslatorService
from services.cache import TranslationCache
from services.language_detector import LanguageDetector
from utils.auth import (
    verify_api_key,
    init_auth,
    create_api_key,
    revoke_api_key,
    list_api_keys,
)
from utils.rate_limiter import RateLimiter
from utils.usage_tracker import UsageTracker
from utils.runtime_config import (
    init_runtime_config,
    get_runtime_config,
    update_runtime_config,
    reset_runtime_config,
)
from utils.languages import (
    FLORES_CODES,
    normalize_language_code,
    is_rtl_language,
    get_language_name,
    LANGUAGE_ALIASES,
)

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.dev.set_exc_info,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.dev.ConsoleRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

slog = structlog.get_logger()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)

logger = logging.getLogger(__name__)

INSTANCE_ID = os.getenv("INSTANCE_ID", "0")
API_VERSION = settings.api_version

translator_service: Optional[TranslatorService] = None
translation_cache: Optional[TranslationCache] = None
language_detector: Optional[LanguageDetector] = None
rate_limiter: Optional[RateLimiter] = None
usage_tracker: Optional[UsageTracker] = None
redis_client: Optional[aioredis.Redis] = None


class TranslationRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=50000)
    source_lang: str = Field(..., description='Source lang code or "auto" for auto-detect')
    target_lang: str = Field(..., description="Target language code")

    @field_validator("text")
    @classmethod
    def normalize_text(cls, v: str) -> str:
        return v.strip()

    @field_validator("source_lang")
    @classmethod
    def validate_source(cls, v: str) -> str:
        if v.lower().strip() in ("auto", "detect", "unknown"):
            return "auto"

        normalized = normalize_language_code(v)

        if not normalized:
            raise ValueError(f"Invalid source language: {v}. Use 'auto' for auto-detect.")

        return normalized

    @field_validator("target_lang")
    @classmethod
    def validate_target(cls, v: str) -> str:
        normalized = normalize_language_code(v)

        if not normalized:
            raise ValueError(f"Invalid target language: {v}")

        return normalized


class TranslationResponse(BaseModel):
    translated_text: str
    source_lang: str
    target_lang: str
    source_lang_name: str
    target_lang_name: str
    character_count: int
    word_count: int
    is_rtl: bool
    cached: bool = False
    auto_detected: bool = False
    detected_confidence: Optional[float] = None
    processing_time_ms: Optional[float] = None
    chunks_processed: Optional[int] = None
    instance_id: Optional[str] = None


class BatchTranslationRequest(BaseModel):
    texts: List[str] = Field(..., min_length=1, max_length=100)
    source_lang: str
    target_lang: str

    @field_validator("texts")
    @classmethod
    def validate_texts(cls, v):
        cleaned = [t.strip() for t in v if t.strip()]

        if not cleaned:
            raise ValueError("At least one non-empty text required")

        return cleaned

    @field_validator("source_lang", "target_lang")
    @classmethod
    def validate_language(cls, v: str) -> str:
        if v.lower() in ("auto", "detect"):
            return "auto"

        normalized = normalize_language_code(v)

        if not normalized:
            raise ValueError(f"Invalid language: {v}")

        return normalized


class BatchTranslationResponse(BaseModel):
    translations: List[str]
    source_lang: str
    target_lang: str
    total_characters: int
    total_words: int
    count: int
    cached_count: int = 0
    processing_time_ms: float
    instance_id: Optional[str] = None


class DetectLanguageRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=40000)


class DetectLanguageResponse(BaseModel):
    detected_lang: str
    detected_lang_name: str
    confidence: float
    is_rtl: bool
    top_candidates: Optional[List[dict]] = None


class LanguageInfo(BaseModel):
    code: str
    name: str
    is_rtl: bool


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
    cache_connected: bool
    languages_supported: int
    version: str
    instance_id: str
    translate_mode: str
    timestamp: datetime


class CreateKeyRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    rate_limit: int = Field(1000, ge=1, le=100000)
    char_limit: Optional[int] = Field(None, ge=1, description="Monthly character cap")
    permissions: List[str] = Field(default=["read"])
    expires_at: Optional[str] = Field(None, description="ISO datetime string")


class CreateKeyResponse(BaseModel):
    api_key: str
    name: str
    rate_limit: int
    char_limit: Optional[int] = None
    permissions: List[str]
    expires_at: Optional[str] = None


class RuntimeConfigUpdate(BaseModel):
    rate_limit_default: Optional[int] = Field(None, ge=1)
    rate_limit_window: Optional[int] = Field(None, ge=60)
    cache_ttl_seconds: Optional[int] = Field(None, ge=60)
    max_batch_size: Optional[int] = Field(None, ge=1, le=200)
    beam_size: Optional[int] = Field(None, ge=1, le=10)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global translator_service, translation_cache, language_detector
    global rate_limiter, usage_tracker, redis_client

    slog.info(
        "starting_translation_api",
        instance=INSTANCE_ID,
        version=API_VERSION,
        mode=settings.translate_mode,
    )

    try:
        redis_client = aioredis.from_url(settings.redis_url, decode_responses=True)
        await redis_client.ping()
        slog.info("redis_connected", instance=INSTANCE_ID)
    except Exception as e:
        slog.warning("redis_connection_failed", error=str(e))
        redis_client = None

    await init_auth(redis_client, settings.admin_api_key)

    translation_cache = TranslationCache()
    await translation_cache.connect()

    rate_limiter = RateLimiter(redis_client)
    usage_tracker = UsageTracker(redis_client)
    init_runtime_config(redis_client)

    try:
        language_detector = LanguageDetector.get_instance()
        await language_detector.initialize()
    except Exception as e:
        slog.warning("language_detector_init_failed", error=str(e))

    slog.info("loading_nllb_model", instance=INSTANCE_ID)

    try:
        translator_service = await TranslatorService.get_instance()
        slog.info("model_loaded", instance=INSTANCE_ID, languages=len(FLORES_CODES))
    except Exception as e:
        slog.error("model_load_failed", error=str(e))
        raise

    slog.info("api_ready", instance=INSTANCE_ID, version=API_VERSION)

    yield

    slog.info("shutting_down", instance=INSTANCE_ID)

    if translator_service:
        await translator_service.cleanup()

    if translation_cache:
        await translation_cache.close()

    if redis_client:
        await redis_client.close()


app = FastAPI(
    title="Translation API",
    description="Meta NLLB-200 3.3B Multilingual Translation — Internal-Only Edition (v4.0)",
    version=API_VERSION,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def add_version_header(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-API-Version"] = API_VERSION
    return response


async def _auto_detect_source(text: str) -> tuple[str, float]:
    if not language_detector or not language_detector.is_ready:
        raise HTTPException(
            status_code=503,
            detail="Language auto-detection not available. Specify source_lang explicitly.",
        )

    loop = asyncio.get_running_loop()
    lang, confidence = await loop.run_in_executor(
        None,
        language_detector.detect_single,
        text[:500],
    )

    if not lang:
        raise HTTPException(status_code=422, detail="Could not auto-detect source language.")

    flores = normalize_language_code(lang)

    if not flores:
        raise HTTPException(
            status_code=422,
            detail=f"Auto-detected '{lang}' but it is not a supported translation language.",
        )

    return flores, confidence


def _build_rate_limit_headers(remaining: int, reset_in: int) -> dict:
    return {
        "X-RateLimit-Remaining": str(remaining),
        "X-RateLimit-Reset": str(reset_in),
    }


@app.get("/health", response_model=HealthResponse, tags=["System"])
async def health_check():
    cache_ok = await translation_cache.is_connected() if translation_cache else False

    return HealthResponse(
        status="healthy" if translator_service and translator_service.is_ready else "initializing",
        model_loaded=translator_service.is_ready if translator_service else False,
        cache_connected=cache_ok,
        languages_supported=len(FLORES_CODES),
        version=API_VERSION,
        instance_id=INSTANCE_ID,
        translate_mode=settings.translate_mode,
        timestamp=datetime.utcnow(),
    )


@app.get("/health/ready", tags=["System"])
async def readiness_check():
    if translator_service and translator_service.is_ready:
        return {"ready": True, "instance_id": INSTANCE_ID, "version": API_VERSION}

    return JSONResponse(
        status_code=503,
        content={"ready": False, "instance_id": INSTANCE_ID, "message": "Model loading..."},
    )


@app.get("/health/live", tags=["System"])
async def liveness_check():
    return {"alive": True, "instance_id": INSTANCE_ID}


@app.post("/api/v1/translate", response_model=TranslationResponse, tags=["Translation"])
async def translate(
    request: TranslationRequest,
    background_tasks: BackgroundTasks,
    http_request: Request,
    api_key: dict = Depends(verify_api_key),
):
    start_time = time.time()

    key_id = api_key.get("api_key", "anonymous")

    if rate_limiter:
        key_limit = api_key.get("rate_limit")
        allowed, remaining, reset_in = await rate_limiter.check_and_get_remaining(key_id, key_limit)

        if not allowed:
            headers = _build_rate_limit_headers(0, reset_in)
            raise HTTPException(status_code=429, detail="Rate limit exceeded", headers=headers)
    else:
        remaining, reset_in = 999, 3600

    char_limit = api_key.get("char_limit")

    if char_limit and usage_tracker:
        within_limit = await usage_tracker.check_char_limit(key_id, char_limit)

        if not within_limit:
            raise HTTPException(
                status_code=402,
                detail=f"Monthly character limit ({char_limit:,}) exceeded. Upgrade your plan.",
            )

    auto_detected = False
    detected_confidence = None

    if request.source_lang == "auto":
        request.source_lang, detected_confidence = await _auto_detect_source(request.text)
        auto_detected = True

    if request.source_lang == request.target_lang:
        raise HTTPException(status_code=422, detail="Source and target languages must differ.")

    cache_status = "MISS"

    if translation_cache:
        cached_result = await translation_cache.get(
            request.text,
            request.source_lang,
            request.target_lang,
        )

        if cached_result:
            cache_status = "HIT"
            processing_time = (time.time() - start_time) * 1000

            if usage_tracker:
                background_tasks.add_task(
                    usage_tracker.record,
                    key_id,
                    len(cached_result),
                    cached=True,
                )

            resp = TranslationResponse(
                translated_text=cached_result,
                source_lang=request.source_lang,
                target_lang=request.target_lang,
                source_lang_name=get_language_name(request.source_lang),
                target_lang_name=get_language_name(request.target_lang),
                character_count=len(cached_result),
                word_count=len(cached_result.split()),
                is_rtl=is_rtl_language(request.target_lang),
                cached=True,
                auto_detected=auto_detected,
                detected_confidence=detected_confidence,
                processing_time_ms=processing_time,
                instance_id=INSTANCE_ID,
            )

            headers = {
                **_build_rate_limit_headers(remaining, reset_in),
                "X-Cache-Status": cache_status,
            }

            return Response(
                content=resp.model_dump_json(),
                media_type="application/json",
                headers=headers,
            )

    if not translator_service or not translator_service.is_ready:
        raise HTTPException(status_code=503, detail="Translation service not ready")

    try:
        translated_text = await translator_service.translate(
            request.text,
            request.source_lang,
            request.target_lang,
        )
    except Exception as e:
        logger.error(f"Translation failed: {e}")
        raise HTTPException(status_code=500, detail="Translation failed. Please try again.")

    if translation_cache:
        background_tasks.add_task(
            translation_cache.set,
            request.text,
            request.source_lang,
            request.target_lang,
            translated_text,
        )

    if usage_tracker:
        background_tasks.add_task(
            usage_tracker.record,
            key_id,
            len(translated_text),
            cached=False,
        )

    processing_time = (time.time() - start_time) * 1000

    resp = TranslationResponse(
        translated_text=translated_text,
        source_lang=request.source_lang,
        target_lang=request.target_lang,
        source_lang_name=get_language_name(request.source_lang),
        target_lang_name=get_language_name(request.target_lang),
        character_count=len(translated_text),
        word_count=len(translated_text.split()),
        is_rtl=is_rtl_language(request.target_lang),
        cached=False,
        auto_detected=auto_detected,
        detected_confidence=detected_confidence,
        processing_time_ms=processing_time,
        instance_id=INSTANCE_ID,
    )

    headers = {
        **_build_rate_limit_headers(remaining, reset_in),
        "X-Cache-Status": "MISS",
    }

    return Response(
        content=resp.model_dump_json(),
        media_type="application/json",
        headers=headers,
    )


@app.post("/api/v1/translate/batch", response_model=BatchTranslationResponse, tags=["Translation"])
async def translate_batch(
    request: BatchTranslationRequest,
    background_tasks: BackgroundTasks,
    api_key: dict = Depends(verify_api_key),
):
    start_time = time.time()
    key_id = api_key.get("api_key", "anonymous")

    if rate_limiter:
        key_limit = api_key.get("rate_limit")
        allowed, remaining, reset_in = await rate_limiter.check_and_get_remaining(key_id, key_limit)

        if not allowed:
            raise HTTPException(status_code=429, detail="Rate limit exceeded")

    if not translator_service or not translator_service.is_ready:
        raise HTTPException(status_code=503, detail="Translation service not ready")

    if request.source_lang == "auto":
        if language_detector and language_detector.is_ready:
            loop = asyncio.get_running_loop()
            detected, _ = await loop.run_in_executor(
                None,
                language_detector.detect_single,
                request.texts[0][:200],
            )
            request.source_lang = normalize_language_code(detected) or "eng_Latn"
        else:
            raise HTTPException(
                status_code=503,
                detail="Auto-detect unavailable for batch. Specify source_lang.",
            )

    cached_count = 0
    results = [None] * len(request.texts)
    uncached_texts, uncached_indices = [], []

    if translation_cache:
        cache_results = await translation_cache.get_batch(
            request.texts,
            request.source_lang,
            request.target_lang,
        )

        for idx, cached_val in cache_results:
            if cached_val:
                results[idx] = cached_val
                cached_count += 1
            else:
                uncached_texts.append(request.texts[idx])
                uncached_indices.append(idx)
    else:
        uncached_texts = list(request.texts)
        uncached_indices = list(range(len(request.texts)))

    if uncached_texts:
        try:
            translations = await translator_service.translate_batch(
                uncached_texts,
                request.source_lang,
                request.target_lang,
            )

            cache_items = []

            for idx, translation in zip(uncached_indices, translations):
                results[idx] = translation

                if translation_cache and not translation.startswith("[TRANSLATION_ERROR]"):
                    cache_items.append((
                        request.texts[idx],
                        request.source_lang,
                        request.target_lang,
                        translation,
                    ))

            if cache_items:
                background_tasks.add_task(translation_cache.set_batch, cache_items)

        except Exception as e:
            logger.error(f"Batch translation failed: {e}")
            raise HTTPException(status_code=500, detail="Batch translation failed.")

    processing_time = (time.time() - start_time) * 1000
    total_chars = sum(len(t) for t in results if t)

    if usage_tracker:
        background_tasks.add_task(
            usage_tracker.record,
            key_id,
            total_chars,
            cached=False,
        )

    return BatchTranslationResponse(
        translations=results,
        source_lang=request.source_lang,
        target_lang=request.target_lang,
        total_characters=total_chars,
        total_words=sum(len(t.split()) for t in results if t),
        count=len(results),
        cached_count=cached_count,
        processing_time_ms=processing_time,
        instance_id=INSTANCE_ID,
    )


@app.post("/api/v1/detect", response_model=DetectLanguageResponse, tags=["Language Detection"])
async def detect_language(
    request: DetectLanguageRequest,
    api_key: dict = Depends(verify_api_key),
):
    if not language_detector or not language_detector.is_ready:
        raise HTTPException(status_code=503, detail="Language detection not available")

    loop = asyncio.get_running_loop()

    candidates = await loop.run_in_executor(
        None,
        language_detector.detect,
        request.text,
        3,
    )

    if not candidates:
        raise HTTPException(status_code=422, detail="Could not detect language")

    top_lang, top_conf = candidates[0]

    top_candidates = [
        {
            "lang": c[0],
            "name": get_language_name(c[0]) or c[0],
            "confidence": round(c[1], 4),
        }
        for c in candidates
    ]

    return DetectLanguageResponse(
        detected_lang=top_lang,
        detected_lang_name=get_language_name(top_lang) or top_lang,
        confidence=top_conf,
        is_rtl=is_rtl_language(top_lang),
        top_candidates=top_candidates,
    )


@app.get("/api/v1/languages", tags=["Languages"])
async def list_languages(search: str = None):
    languages = []

    for code, name in FLORES_CODES.items():
        if search:
            sl = search.lower()
            if sl not in code.lower() and sl not in name.lower():
                continue

        languages.append(LanguageInfo(code=code, name=name, is_rtl=is_rtl_language(code)))

    languages.sort(key=lambda x: x.name)

    return {"languages": languages, "total": len(languages)}


@app.get("/api/v1/languages/{code}", response_model=LanguageInfo, tags=["Languages"])
async def get_language(code: str):
    normalized = normalize_language_code(code)

    if not normalized:
        raise HTTPException(status_code=404, detail=f"Language not found: {code}")

    return LanguageInfo(
        code=normalized,
        name=get_language_name(normalized),
        is_rtl=is_rtl_language(normalized),
    )


@app.get("/api/v1/aliases", tags=["Languages"])
async def list_aliases():
    return {"aliases": LANGUAGE_ALIASES}


@app.get("/api/v1/keys/me", tags=["Keys"])
async def get_my_key_info(api_key: dict = Depends(verify_api_key)):
    return {
        "key_prefix": api_key.get("api_key_prefix"),
        "name": api_key.get("name"),
        "rate_limit": api_key.get("rate_limit"),
        "char_limit": api_key.get("char_limit"),
        "permissions": api_key.get("permissions"),
        "expires_at": api_key.get("expires_at"),
        "created_at": api_key.get("created_at"),
        "last_used_at": api_key.get("last_used_at"),
    }


@app.get("/api/v1/keys/me/usage", tags=["Keys"])
async def get_my_usage(
    period: str = Query(None, description="Billing period YYYY-MM (default: current)"),
    api_key: dict = Depends(verify_api_key),
):
    if not usage_tracker:
        raise HTTPException(status_code=503, detail="Usage tracking unavailable")

    key_id = api_key.get("api_key", "")
    stats = await usage_tracker.get_usage(key_id, period)

    char_limit = api_key.get("char_limit")

    return {
        **stats,
        "char_limit": char_limit,
        "chars_remaining": max(0, char_limit - stats["chars"]) if char_limit else None,
        "limit_pct_used": round(stats["chars"] / char_limit * 100, 1) if char_limit else None,
    }


@app.get("/api/v1/stats", tags=["Admin"])
async def get_stats(api_key: dict = Depends(verify_api_key)):
    cache_stats = await translation_cache.get_stats() if translation_cache else {}
    translator_stats = translator_service.get_stats() if translator_service else {}
    platform_usage = await usage_tracker.get_platform_stats() if usage_tracker else {}

    return {
        "version": API_VERSION,
        "translator": translator_stats,
        "cache": cache_stats,
        "usage": platform_usage,
        "languages_supported": len(FLORES_CODES),
        "instance_id": INSTANCE_ID,
    }


@app.delete("/api/v1/cache", tags=["Admin"])
async def clear_cache(api_key: dict = Depends(verify_api_key)):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    if translation_cache:
        count = await translation_cache.clear_all()
        return {"message": f"Cleared {count} cached translations"}

    return {"message": "Cache not available"}


@app.post("/api/v1/keys", response_model=CreateKeyResponse, tags=["Admin"])
async def create_key(
    request: CreateKeyRequest,
    api_key: dict = Depends(verify_api_key),
):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    new_key = f"trans_{secrets.token_hex(24)}"

    success = await create_api_key(
        new_key,
        request.name,
        request.rate_limit,
        request.permissions,
        request.expires_at,
        request.char_limit,
    )

    if not success:
        raise HTTPException(status_code=500, detail="Failed to create API key")

    return CreateKeyResponse(
        api_key=new_key,
        name=request.name,
        rate_limit=request.rate_limit,
        char_limit=request.char_limit,
        permissions=request.permissions,
        expires_at=request.expires_at,
    )


@app.delete("/api/v1/keys/{key_or_prefix}", tags=["Admin"])
async def delete_key(
    key_or_prefix: str,
    api_key: dict = Depends(verify_api_key),
):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    success = await revoke_api_key(key_or_prefix)

    if success:
        return {"message": "API key revoked"}

    raise HTTPException(status_code=404, detail="API key not found")


@app.get("/api/v1/keys", tags=["Admin"])
async def get_keys(api_key: dict = Depends(verify_api_key)):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    return {"keys": await list_api_keys()}


@app.get("/api/v1/admin/config", tags=["Admin"])
async def get_config(api_key: dict = Depends(verify_api_key)):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    runtime = await get_runtime_config()

    return {
        "env_defaults": {
            "rate_limit_default": settings.rate_limit_default,
            "rate_limit_window": settings.rate_limit_window,
            "cache_ttl_seconds": settings.cache_ttl_seconds,
            "max_batch_size": settings.max_batch_size,
            "beam_size": settings.beam_size,
        },
        "runtime_overrides": runtime,
        "note": "runtime_overrides take precedence over env_defaults",
    }


@app.put("/api/v1/admin/config", tags=["Admin"])
async def update_config(
    updates: RuntimeConfigUpdate,
    api_key: dict = Depends(verify_api_key),
):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    payload = {k: v for k, v in updates.model_dump().items() if v is not None}

    if not payload:
        raise HTTPException(status_code=400, detail="No values to update")

    try:
        new_config = await update_runtime_config(payload)
        return {"message": "Config updated", "config": new_config}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.delete("/api/v1/admin/config", tags=["Admin"])
async def reset_config(api_key: dict = Depends(verify_api_key)):
    if "admin" not in api_key.get("permissions", []):
        raise HTTPException(status_code=403, detail="Admin permission required")

    await reset_runtime_config()
    return {"message": "Runtime config cleared — .env defaults active"}


@app.get("/", tags=["Info"])
async def root():
    return {
        "name": "Translation API",
        "version": API_VERSION,
        "description": "Meta NLLB-200 3.3B — Internal-Only Edition",
        "languages_supported": len(FLORES_CODES),
        "documentation": "/docs",
        "health": "/health",
        "instance_id": INSTANCE_ID,
        "translate_mode": settings.translate_mode,
        "features": [
            "200+ languages",
            "auto source detection",
            "batch translation",
            "redis cache",
            "per-key rate limiting",
            "monthly char metering",
            "hot-reload config",
        ],
    }


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": True, "message": exc.detail, "status_code": exc.status_code},
        headers=exc.headers or {},
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)

    return JSONResponse(
        status_code=500,
        content={"error": True, "message": "Internal server error", "status_code": 500},
    )
MAINEOF

print_success "Main application created"

#############################################
# STEP 18: Model Download Script
#############################################
print_header "STEP 18: Model Download Script"

cat > "${TRANSLATE_API_DIR}/download-model.sh" << 'DOWNLOADEOF'
#!/bin/bash
set -e

MODEL_DIR="/opt/translate-api/models"
MODEL_NAME="nllb-200-3.3B-ct2-int8"
MODEL_PATH="${MODEL_DIR}/${MODEL_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  NLLB-200 3.3B INT8 — Model Download   ${NC}"
echo -e "${BLUE}  v4: Python huggingface_hub            ${NC}"
echo -e "${BLUE}========================================${NC}"

if [ -d "$MODEL_PATH" ] && [ -f "$MODEL_PATH/model.bin" ]; then
    echo -e "${YELLOW}Model already at ${MODEL_PATH}${NC}"
    read -p "Re-download? (yes/no): " REDOWNLOAD
    [ "$REDOWNLOAD" != "yes" ] && echo "Keeping existing model." && exit 0
fi

mkdir -p "$MODEL_DIR"

HF_TOKEN="${HF_TOKEN:-}"

if [ -z "$HF_TOKEN" ]; then
    echo -e "${YELLOW}No HF_TOKEN in environment.${NC}"
    read -p "Hugging Face token (or press Enter for anonymous): " HF_TOKEN
fi

if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    if ! python3 -m pip --version &>/dev/null; then
        echo "pip not found — attempting bootstrap..."
        command -v dnf &>/dev/null && sudo dnf install -y python3-pip &>/dev/null || true
        command -v apt-get &>/dev/null && sudo apt-get install -y python3-pip &>/dev/null || true
        python3 -m ensurepip --upgrade 2>/dev/null || true

        python3 -m pip --version &>/dev/null || {
            echo -e "${RED}✗ Cannot install pip. Try: apt-get install -y python3-pip${NC}"
            exit 1
        }
    fi

    echo "Installing huggingface_hub..."
    python3 -m pip install huggingface_hub || python3 -m pip install --break-system-packages huggingface_hub || {
        echo -e "${RED}✗ Failed to install huggingface_hub${NC}"
        exit 1
    }
fi

echo ""
echo -e "${BLUE}Downloading NLLB-200 3.3B INT8 (~4GB)...${NC}"
echo "This can take 10–30 minutes depending on connection."
echo ""

python3 << PYEOF
import os
import sys

from huggingface_hub import snapshot_download, login

token = os.environ.get("HF_TOKEN", "${HF_TOKEN}")

if token:
    login(token=token, add_to_git_credential=False)
    print("Logged in to HuggingFace")
else:
    print("Attempting anonymous download...")

repos = [
    "OpenNMT/nllb-200-3.3B-ct2-int8",
]

success = False

for repo in repos:
    try:
        print(f"Trying: {repo}")
        path = snapshot_download(
            repo_id=repo,
            local_dir="${MODEL_PATH}",
            local_dir_use_symlinks=False,
            ignore_patterns=["*.msgpack", "*.h5", "flax_model*", "tf_model*"],
        )
        print(f"Downloaded to: {path}")
        success = True
        break
    except Exception as e:
        print(f"Failed ({repo}): {e}")

if not success:
    print("All repos failed. Try manually:")
    print("  pip install huggingface_hub")
    print("  huggingface-cli download OpenNMT/nllb-200-3.3B-ct2-int8 --local-dir ${MODEL_PATH}")
    sys.exit(1)

spm_path = "${MODEL_PATH}/sentencepiece.bpe.model"

if not os.path.exists(spm_path):
    print("Downloading sentencepiece.bpe.model from facebook/nllb-200-3.3B...")
    from huggingface_hub import hf_hub_download

    hf_hub_download(
        repo_id="facebook/nllb-200-3.3B",
        filename="sentencepiece.bpe.model",
        local_dir="${MODEL_PATH}",
        local_dir_use_symlinks=False,
    )

print("Done!")
PYEOF

if [ -f "$MODEL_PATH/model.bin" ]; then
    echo -e "${GREEN}✔ Model download complete!${NC}"
    echo -e "${GREEN}  Path: ${MODEL_PATH}${NC}"
    ls -lh "$MODEL_PATH/"
else
    echo -e "${RED}✗ model.bin not found — download may have failed.${NC}"
    exit 1
fi
DOWNLOADEOF

chmod 700 "${TRANSLATE_API_DIR}/download-model.sh"
print_success "Model download script created"

#############################################
# STEP 19: Helper Scripts
#############################################
print_header "STEP 19: Helper Scripts"

echo "${ADMIN_API_KEY}" > "${TRANSLATE_API_DIR}/.api_key"
chmod 600 "${TRANSLATE_API_DIR}/.api_key"

cat > "${TRANSLATE_API_DIR}/test-translate.sh" << 'TESTEOF'
#!/bin/bash
TEXT=${1:-"Hello, how are you?"}
SOURCE=${2:-"auto"}
TARGET=${3:-"arb_Arab"}
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key found" && exit 1

echo "Testing: $TEXT | $SOURCE -> $TARGET"

curl -si -X POST "http://localhost:5080/api/v1/translate" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "{\"text\": \"$TEXT\", \"source_lang\": \"$SOURCE\", \"target_lang\": \"$TARGET\"}"
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/test-translate.sh"

cat > "${TRANSLATE_API_DIR}/test-batch.sh" << 'TESTEOF'
#!/bin/bash
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key found" && exit 1

echo "Testing batch translation..."

curl -s -X POST "http://localhost:5080/api/v1/translate/batch" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"texts": ["Hello world", "How are you?", "Thank you very much"], "source_lang": "auto", "target_lang": "arb_Arab"}' \
  | python3 -m json.tool
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/test-batch.sh"

cat > "${TRANSLATE_API_DIR}/detect-language.sh" << 'TESTEOF'
#!/bin/bash
TEXT=${1:-"مرحبا بالعالم"}
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key found" && exit 1

curl -s -X POST "http://localhost:5080/api/v1/detect" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "{\"text\": \"$TEXT\"}" | python3 -m json.tool
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/detect-language.sh"

cat > "${TRANSLATE_API_DIR}/list-languages.sh" << 'TESTEOF'
#!/bin/bash
SEARCH=${1:-""}

if [ -n "$SEARCH" ]; then
  curl -s "http://localhost:5080/api/v1/languages?search=$SEARCH" | python3 -m json.tool
else
  curl -s "http://localhost:5080/api/v1/languages" | python3 -m json.tool
fi
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/list-languages.sh"

cat > "${TRANSLATE_API_DIR}/create-api-key.sh" << 'TESTEOF'
#!/bin/bash
NAME=${1:-"new-key"}
RATE_LIMIT=${2:-1000}
CHAR_LIMIT=${3:-""}
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key" && exit 1

BODY="{\"name\": \"$NAME\", \"rate_limit\": $RATE_LIMIT, \"permissions\": [\"read\"]"

[ -n "$CHAR_LIMIT" ] && BODY="$BODY, \"char_limit\": $CHAR_LIMIT"

BODY="$BODY}"

echo "Creating key: $NAME (rate: $RATE_LIMIT/hr, chars: ${CHAR_LIMIT:-unlimited})"

curl -s -X POST "http://localhost:5080/api/v1/keys" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "$BODY" | python3 -m json.tool
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/create-api-key.sh"

cat > "${TRANSLATE_API_DIR}/list-api-keys.sh" << 'TESTEOF'
#!/bin/bash
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key" && exit 1

curl -s "http://localhost:5080/api/v1/keys" \
  -H "X-API-Key: $API_KEY" | python3 -m json.tool
TESTEOF

chmod +x "${TRANSLATE_API_DIR}/list-api-keys.sh"

cat > "${TRANSLATE_API_DIR}/usage.sh" << 'USAGEEOF'
#!/bin/bash
PERIOD=${1:-""}
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key" && exit 1

URL="http://localhost:5080/api/v1/keys/me/usage"

[ -n "$PERIOD" ] && URL="${URL}?period=${PERIOD}"

echo "=== Usage Stats (${PERIOD:-current month}) ==="

curl -s "$URL" -H "X-API-Key: $API_KEY" | python3 -m json.tool
USAGEEOF

chmod +x "${TRANSLATE_API_DIR}/usage.sh"

cat > "${TRANSLATE_API_DIR}/config.sh" << 'CONFIGSHEOF'
#!/bin/bash
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key" && exit 1

if [ "$1" = "reset" ]; then
  echo "Resetting runtime config to .env defaults..."
  curl -s -X DELETE "http://localhost:5080/api/v1/admin/config" \
    -H "X-API-Key: $API_KEY" | python3 -m json.tool
elif [ -n "$1" ]; then
  BODY="{"
  FIRST=true

  for arg in "$@"; do
    KEY=$(echo "$arg" | cut -d= -f1)
    VAL=$(echo "$arg" | cut -d= -f2)

    $FIRST || BODY="$BODY,"
    BODY="$BODY\"$KEY\": $VAL"
    FIRST=false
  done

  BODY="$BODY}"

  echo "Updating config: $BODY"

  curl -s -X PUT "http://localhost:5080/api/v1/admin/config" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -d "$BODY" | python3 -m json.tool
else
  echo "=== Runtime Config ==="
  curl -s "http://localhost:5080/api/v1/admin/config" \
    -H "X-API-Key: $API_KEY" | python3 -m json.tool
fi
CONFIGSHEOF

chmod +x "${TRANSLATE_API_DIR}/config.sh"

cat > "${TRANSLATE_API_DIR}/health.sh" << 'HEALTHEOF'
#!/bin/bash
echo "=== Nginx + API Health ==="
curl -s "http://localhost:5080/health" | python3 -m json.tool 2>/dev/null || echo "Not responding"

echo ""
echo "=== Instance 1 ==="
docker exec translate-api-1 curl -sf http://localhost:8000/health/ready 2>/dev/null | python3 -m json.tool || echo "Instance 1 not ready"
HEALTHEOF

chmod +x "${TRANSLATE_API_DIR}/health.sh"

cat > "${TRANSLATE_API_DIR}/restart.sh" << 'RESTARTEOF'
#!/bin/bash
INSTANCES=$(docker ps --format '{{.Names}}' | grep translate-api-)

for INST in $INSTANCES; do
  echo "Restarting $INST..."
  docker compose --project-directory /opt/translate-api restart "$INST"

  echo "Waiting for $INST readiness..."

  for i in $(seq 1 60); do
    docker exec "$INST" curl -sf http://localhost:8000/health/ready > /dev/null 2>&1 && break
    sleep 5
  done

  echo "$INST ready."
done

echo "Rolling restart complete."
RESTARTEOF

chmod +x "${TRANSLATE_API_DIR}/restart.sh"

cat > "${TRANSLATE_API_DIR}/logs.sh" << 'LOGSEOF'
#!/bin/bash
SERVICE=${1:-""}

if [ -n "$SERVICE" ]; then
  docker compose --project-directory /opt/translate-api logs -f "$SERVICE"
else
  docker compose --project-directory /opt/translate-api logs -f translate-api-1 translate-nginx
fi
LOGSEOF

chmod +x "${TRANSLATE_API_DIR}/logs.sh"

cat > "${TRANSLATE_API_DIR}/clear-cache.sh" << 'CACHEEOF'
#!/bin/bash
API_KEY="${ADMIN_API_KEY:-$(cat /opt/translate-api/.api_key 2>/dev/null)}"

[ -z "$API_KEY" ] && echo "ERROR: No API key" && exit 1

echo "Clearing translation cache..."

curl -s -X DELETE "http://localhost:5080/api/v1/cache" \
  -H "X-API-Key: $API_KEY" | python3 -m json.tool
CACHEEOF

chmod +x "${TRANSLATE_API_DIR}/clear-cache.sh"

print_success "Helper scripts created"

#############################################
# STEP 20: Gate Script
#############################################
print_header "STEP 20: Gate Script"

cat > "${TRANSLATE_API_DIR}/gate.sh" << GATEEOF
#!/usr/bin/env bash
# Pre-launch gate for translate-api — fails closed.
# Run before every first build/start and before every post-edit restart.
set -e

cd ${TRANSLATE_API_DIR}

docker compose config --quiet

test "\$(stat -c '%a' .env)" = "600"
test -s .env

grep -q '127.0.0.1:5080:5080' docker-compose.yml

test -f models/nllb-200-3.3B-ct2-int8/model.bin

if sed -n '/^  translate-redis:/,/^  [a-z]/p' docker-compose.yml | grep -q 'ports:'; then
  echo "WARNING: redis port exposed"
  exit 1
fi

echo "Gate passed."
GATEEOF

chmod 700 "${TRANSLATE_API_DIR}/gate.sh"
print_success "gate.sh created"

#############################################
# STEP 21: Deployment Notes
#############################################
print_header "STEP 21: Deployment Notes"

cat > "${TRANSLATE_API_DIR}/DEPLOYMENT-NOTES.md" << NOTESEOF
# Translation API v4 Deployment Notes

Mode: single
VM target: 8 vCPU / 24 GB
API CPU cap: 6.0
API memory limit: 14G
API memory reservation: 10G
Nginx bind: 127.0.0.1:5080 (hardcoded)
Redis: internal only, no host port
Public exposure: none — internal reverse proxy / VPN only

Generated on: $(date)
NOTESEOF

chmod 640 "${TRANSLATE_API_DIR}/DEPLOYMENT-NOTES.md"
print_success "DEPLOYMENT-NOTES.md created"

#############################################
# STEP 22: Hard Stop — Review Before Build
#############################################
print_header "STEP 22: Review Gate — Hard Stop"

print_success "Files generated successfully in ${TRANSLATE_API_DIR}"
print_warning "This v4 installer intentionally stops before build/start."
print_info "No Docker build or container start has been executed."

echo ""
echo "Next steps:"
echo "  1. Inspect generated files:"
echo "     cd ${TRANSLATE_API_DIR}"
echo "     find . -maxdepth 3 -type f -printf '%M %u:%g %p\n' | sort"
echo ""
echo "  2. Review secrets permission:"
echo "     stat -c '%a %U:%G %n' .env"
echo ""
echo "  3. Download the NLLB model:"
echo "     cd ${TRANSLATE_API_DIR}"
echo "     ./download-model.sh"
echo ""
echo "  4. Run the launch gate:"
echo "     ./gate.sh"
echo ""
echo "  5. Build and start only after review:"
echo "     docker compose build --pull"
echo "     docker compose up -d"
echo ""
echo "  6. Smoke test:"
echo "     docker compose ps"
echo "     ss -lntp | grep 5080"
echo "     curl -i http://127.0.0.1:5080/health/live"
echo "     curl -i http://127.0.0.1:5080/health/ready"
echo ""
echo "Admin API key saved to:"
echo "  ${TRANSLATE_API_DIR}/.api_key"
echo ""
print_warning "Do not paste .env or .api_key into chat, git, or tickets."

exit 0