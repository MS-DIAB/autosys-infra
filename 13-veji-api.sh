#!/usr/bin/env bash
# =============================================================================
# 13-veji-api.sh
# -----------------------------------------------------------------------------
# VEJI-V2 Decision API — FastAPI wrapper around loaiabdalslam/VEJI-V2.
#
# Usage:
#   ./13-veji-api.sh              # install / idempotent re-run
#   ./13-veji-api.sh --force      # regenerate all generated files
#   ./13-veji-api.sh --down       # stop and remove the stack (keeps models/logs)
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration --------------------------------
INSTALL_DIR="${VEJI_INSTALL_DIR:-/opt/veji-api}"
NETWORK_NAME="${AUTOSYS_NETWORK:-proxy-network}"
DOMAIN="${VEJI_DOMAIN:-veji.${BASE_DOMAIN:-example.com}}"
TIMEZONE="${VEJI_TIMEZONE:-${TIMEZONE:-UTC}}"
INTERNAL_NETWORK_NAME="${VEJI_INTERNAL_NETWORK:-veji-internal}"

VEJI_PORT="${VEJI_PORT:-5090}"
MODEL_ID="${VEJI_MODEL_ID:-loaiabdalslam/VEJI-V2}"
DEVICE="${VEJI_DEVICE:-cpu}"

# Resource caps — small model, but the frozen MiniLM encoder and the
# compilation step can spike; keep generous headroom.
API_CPUS="${VEJI_CPUS:-2.0}"
API_MEM_LIMIT="${VEJI_MEM_LIMIT:-4g}"
API_MEM_RESERVATION="${VEJI_MEM_RESERVATION:-2g}"

MAX_CACHED_STATES="${VEJI_MAX_CACHED_STATES:-16}"
MAX_CONTEXT_CHARS="${VEJI_MAX_CONTEXT_CHARS:-250000}"

# Abstain threshold: 0.0 disables abstention; values <=1.0 force "uncertain"
# below the threshold. The model card default is 0.55; leave as-is unless
# you have calibration data of your own.
ABSTAIN_THRESHOLD="${VEJI_ABSTAIN_THRESHOLD:-}"

# Encoder fallback: if true, the encoder falls back to PyTorch when ONNX is
# unavailable; if false, a missing ONNX backend is a hard error.
ENCODER_FALLBACK="${VEJI_ENCODER_FALLBACK:-true}"

FORCE=false
ACTION="up"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --down)  ACTION="down" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ------------------------------ Colors / logging -----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
trap 'log_error "Install failed at line $LINENO."' ERR

# write_file <path> <success_message> : reads heredoc from stdin, skips if file exists unless --force
write_file() {
  local path="$1"
  local msg="${2:-Wrote $path}"
  if [[ -f "$path" && "$FORCE" != true ]]; then
    log_info "Skipping existing file: $path (use --force to regenerate)"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  log_success "$msg"
}

# =============================================================================
# 0. Teardown
# =============================================================================
if [[ "$ACTION" == "down" ]]; then
  log_info "Stopping VEJI API stack..."
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    (cd "$INSTALL_DIR" && docker compose down)
    log_success "Stack stopped. Models and logs left under $INSTALL_DIR."
  else
    log_warn "No docker-compose.yml found at $INSTALL_DIR."
  fi
  exit 0
fi

# =============================================================================
# 0.5. Hugging Face Token
# =============================================================================
if [[ -z "${VEJI_HF_TOKEN:-}" ]]; then
  echo ""
  log_info "A Hugging Face token is needed to download the VEJI-V2 model and"
  log_info "the sentence-transformers encoder.  You can create one at:"
  log_info "  https://huggingface.co/settings/tokens"
  echo ""
  read -rp "$(echo -e "${CYAN}Enter your Hugging Face token (or press Enter to skip):${NC} ")" HF_TOKEN_INPUT
  if [[ -n "$HF_TOKEN_INPUT" ]]; then
    VEJI_HF_TOKEN="$HF_TOKEN_INPUT"
    log_success "Token accepted."
  else
    VEJI_HF_TOKEN=""
    log_warn "No token provided.  Download may fail if Hugging Face rate-limits you."
  fi
else
  VEJI_HF_TOKEN="${VEJI_HF_TOKEN}"
  log_success "Using Hugging Face token from environment (VEJI_HF_TOKEN)."
fi

# =============================================================================
# 1. Pre-flight
# =============================================================================
log_info "Running pre-flight checks..."

command -v docker >/dev/null 2>&1 || { log_error "docker is not installed."; exit 1; }
docker compose version >/dev/null 2>&1 || { log_error "docker compose plugin missing."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl is required."; exit 1; }

if command -v free >/dev/null 2>&1; then
  AVAIL_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
  if [[ "${AVAIL_MEM_MB:-0}" -lt 3000 ]]; then
    log_warn "Only ${AVAIL_MEM_MB}MB available — the frozen encoder plus PyTorch may OOM."
  else
    log_success "Memory check passed (${AVAIL_MEM_MB}MB available)."
  fi
else
  log_warn "Cannot check available memory ('free' not found).  Ensure at least 3GB is free."
fi

AVAIL_DISK_GB=$(df -Pm "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
if [[ "${AVAIL_DISK_GB:-0}" -lt 5 ]]; then
  log_warn "Less than 5GB free at $(dirname "$INSTALL_DIR") — model + image may not fit."
else
  log_success "Disk check passed (${AVAIL_DISK_GB}GB available)."
fi

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log_success "Docker network '$NETWORK_NAME' exists."
else
  log_warn "Network '$NETWORK_NAME' not found — creating it (NPM script normally does this)."
  docker network create "$NETWORK_NAME"
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|^)${VEJI_PORT}$"; then
  log_warn "Port ${VEJI_PORT} already in use on this host."
fi

# =============================================================================
# 2. Directory scaffold
# =============================================================================
log_info "Scaffolding $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"/{app,models/veji-v2,models/hf-cache,logs,scripts}
log_success "Directories ready."

# =============================================================================
# 3. .env
# =============================================================================
write_file "$INSTALL_DIR/.env" <<EOF
# VEJI-V2 Decision API — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)

INSTALL_DIR=${INSTALL_DIR}
NETWORK_NAME=${NETWORK_NAME}
INTERNAL_NETWORK_NAME=${INTERNAL_NETWORK_NAME}
DOMAIN=${DOMAIN}
TIMEZONE=${TIMEZONE}

VEJI_PORT=${VEJI_PORT}
VEJI_MODEL_ID=${MODEL_ID}
VEJI_DEVICE=${DEVICE}

VEJI_CPUS=${API_CPUS}
VEJI_MEM_LIMIT=${API_MEM_LIMIT}
VEJI_MEM_RESERVATION=${API_MEM_RESERVATION}

VEJI_MAX_CACHED_STATES=${MAX_CACHED_STATES}
VEJI_MAX_CONTEXT_CHARS=${MAX_CONTEXT_CHARS}

# Leave blank to let the model card default (0.55) apply.
# Set to a float in [0,1] to override per-deployment.
VEJI_ABSTAIN_THRESHOLD=${ABSTAIN_THRESHOLD}

# Encoder fallback: true = fall back to PyTorch; false = hard error if ONNX missing.
VEJI_ENCODER_FALLBACK=${ENCODER_FALLBACK}

# Hugging Face token — needed for model/encoder download.
HF_TOKEN=${VEJI_HF_TOKEN}

LOG_LEVEL=INFO
EOF
chmod 600 "$INSTALL_DIR/.env"
log_success "Wrote .env (mode 600)"

# =============================================================================
# 4. docker-compose.yml
# =============================================================================
# The heredoc is intentionally UNQUOTED so that Bash interpolates variables
# like ${INTERNAL_NETWORK_NAME} directly into the YAML. Docker Compose does
# not support using interpolated variables as dictionary keys (like network names).
write_file "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  veji-api:
    build: .
    container_name: veji-api
    restart: unless-stopped
    env_file: .env
    environment:
      - TZ=${TIMEZONE}
      - VEJI_MODEL_DIR=/models/veji-v2
      - HF_HOME=/models/hf-cache
    # Localhost-only by design, matching translate-api / stt-api conventions.
    # Public path is Cloudflare -> NPM -> veji-api:8000 on ${NETWORK_NAME}.
    ports:
      - "127.0.0.1:${VEJI_PORT}:8000"
    volumes:
      - ./models/veji-v2:/models/veji-v2
      - ./models/hf-cache:/models/hf-cache
      - ./logs:/app/logs
    networks:
      - ${INTERNAL_NETWORK_NAME}
      - ${NETWORK_NAME}
    deploy:
      resources:
        limits:
          cpus: "${API_CPUS}"
          memory: ${API_MEM_LIMIT}
        reservations:
          memory: ${API_MEM_RESERVATION}
    healthcheck:
      test:
        - CMD
        - curl
        - -f
        - http://localhost:8000/health
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s

networks:
  ${INTERNAL_NETWORK_NAME}:
    driver: bridge
  ${NETWORK_NAME}:
    external: true
EOF
log_success "Wrote docker-compose.yml"

# =============================================================================
# 4b. .dockerignore
# =============================================================================
write_file "$INSTALL_DIR/.dockerignore" <<'DIEOF'
# Keep the build context small — model weights and logs must not be sent
# to the Docker daemon.
models/
logs/
.env
*.sh
*.md
.git/
__pycache__/
*.pyc
DIEOF
log_success "Wrote .dockerignore"

# =============================================================================
# 5. Dockerfile
# =============================================================================
write_file "$INSTALL_DIR/Dockerfile" <<'DOCKEREOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gcc \
    g++ \
    libgomp1 \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HUB_DISABLE_TELEMETRY=1

RUN pip install --upgrade pip && \
    pip install --extra-index-url https://download.pytorch.org/whl/cpu \
        -r /app/requirements.txt

COPY app /app/app
COPY scripts /app/scripts

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--log-level", "info"]
DOCKEREOF
log_success "Wrote Dockerfile"

# =============================================================================
# 6. requirements.txt
# =============================================================================
write_file "$INSTALL_DIR/requirements.txt" <<'REQEOF'
# --- API layer ---------------------------------------------------------------
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
prometheus-client==0.20.0
python-multipart==0.0.9

# --- Model + encoder ---------------------------------------------------------
# CPU-only torch so the image stays small and never pulls CUDA wheels.
torch==2.5.1+cpu
numpy==1.26.4
sentence-transformers==3.3.1
transformers==4.46.3
huggingface_hub==0.26.2
safetensors==0.4.5

# --- Utility -----------------------------------------------------------------
PyYAML==6.0.2
REQEOF
log_success "Wrote requirements.txt"

# =============================================================================
# 7. app/__init__.py
# =============================================================================
write_file "$INSTALL_DIR/app/__init__.py" <<'EOF'
__version__ = "1.0.0"
EOF

# =============================================================================
# 8. app/schemas.py — Pydantic request/response models
# =============================================================================
write_file "$INSTALL_DIR/app/schemas.py" <<'PYEOF'
"""
Request/response schemas for the VEJI-V2 Decision API.

The `Question` shape mirrors what veji.py's forward_question expects:
  - `id`           : caller-supplied correlation id, echoed back in results
  - `type`         : one of TYPE_NAMES in veji.py
  - `semantic_type`: optional override of `type` for the type embedding
  - `instruction`  : the natural-language question
  - `options`      : 2..64 candidate strings
"""
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, field_validator

# Kept in sync with veji.py TYPE_NAMES. The API rejects anything else so a
# typo surfaces as a 422 with the allowed set, rather than silently falling
# through to the "choice" type embedding inside the model.
VEJI_TYPE_NAMES = {
    "choice", "score", "noul", "route", "rank", "span", "boolean",
    "execution", "uncertainty", "multi_hop", "classification", "extraction",
}


class Question(BaseModel):
    id: str = Field(..., min_length=1, max_length=128)
    type: str = Field(..., description=f"One of: {sorted(VEJI_TYPE_NAMES)}")
    semantic_type: Optional[str] = Field(
        None,
        description="Optional override of `type` for the learned type embedding.",
    )
    instruction: str = Field(..., min_length=1, max_length=8000)
    options: List[str] = Field(..., min_length=2, max_length=64)

    @field_validator("type")
    @classmethod
    def _check_type(cls, v: str) -> str:
        if v not in VEJI_TYPE_NAMES:
            raise ValueError(
                f"unknown question type {v!r}; allowed: {sorted(VEJI_TYPE_NAMES)}"
            )
        return v

    @field_validator("options")
    @classmethod
    def _dedupe_options(cls, v: List[str]) -> List[str]:
        seen, out = set(), []
        for opt in v:
            opt = opt.strip()
            if opt and opt not in seen:
                seen.add(opt)
                out.append(opt)
        if len(out) < 2:
            raise ValueError("at least 2 distinct non-empty options required")
        return out


class CompileRequest(BaseModel):
    state: str = Field(..., min_length=1, description="The long context to compile.")


class CompileResponse(BaseModel):
    state_id: str = Field(..., description="SHA-256 of the state text. Use with /v1/decide/compiled.")
    was_cached: bool
    char_count: int
    compile_time_s: float
    cached_states: int


class DecideRequest(BaseModel):
    state: str = Field(..., min_length=1)
    questions: List[Question] = Field(..., min_length=1, max_length=512)
    abstain_threshold: Optional[float] = Field(None, ge=0.0, le=1.0)


class DecideRequestCompiled(BaseModel):
    state_id: str = Field(..., min_length=64, max_length=64)
    questions: List[Question] = Field(..., min_length=1, max_length=512)
    abstain_threshold: Optional[float] = Field(None, ge=0.0, le=1.0)


class DecideResponse(BaseModel):
    results: List[Dict[str, Any]]
    question_count: int
    abstain_threshold: Optional[float]
    decision_time_s: float
    throughput_qps: Optional[float]


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
    device: str
    encoder_backend: Optional[str]
    cached_states: int
    version: str


class InfoResponse(BaseModel):
    model_id: str
    device: str
    loaded_at_unix: Optional[float]
    encoder_backend: Optional[str]
    cached_states: int
    cache_capacity: int
    model_config_json: Dict[str, Any]
    version: str
PYEOF
log_success "Wrote app/schemas.py"

# =============================================================================
# 9. app/engine.py — model loader + LRU-compiled-state cache
# =============================================================================
write_file "$INSTALL_DIR/app/engine.py" <<'PYEOF'
"""
Thread-safe wrapper around VEJI-V2.

All model calls are serialized under a single lock. The head itself is tiny
(3.28M params) and the encoder is the dominant cost, so serializing is not a
bottleneck at the documented ~87 q/s warm rate, and it removes any question
about thread-safety of the loaded checkpoint.
"""
import hashlib
import json
import logging
import os
import sys
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("veji.engine")

MODEL_ID = os.environ.get("VEJI_MODEL_ID", "loaiabdalslam/VEJI-V2")
MODEL_DIR = os.environ.get("VEJI_MODEL_DIR", "/models/veji-v2")
DEVICE = os.environ.get("VEJI_DEVICE", "cpu")
MAX_CACHED_STATES = int(os.environ.get("VEJI_MAX_CACHED_STATES", "16"))
MAX_CONTEXT_CHARS = int(os.environ.get("VEJI_MAX_CONTEXT_CHARS", "250000"))

# Empty string -> None -> veji.py falls back to cfg.confidence_threshold (0.55).
_thresh_raw = os.environ.get("VEJI_ABSTAIN_THRESHOLD", "").strip()
ABSTAIN_THRESHOLD: Optional[float] = float(_thresh_raw) if _thresh_raw else None

# Encoder fallback: "true" allows PyTorch fallback; "false" requires ONNX.
ENCODER_FALLBACK = os.environ.get("VEJI_ENCODER_FALLBACK", "true").strip().lower() == "true"


class CompiledStateCache:
    """Bounded LRU keyed by the SHA-256 of the state text."""

    def __init__(self, max_size: int):
        self.max_size = max_size
        self._store: "OrderedDict[str, Any]" = OrderedDict()
        self._lock = threading.Lock()

    @staticmethod
    def key_for(state: str) -> str:
        return hashlib.sha256(state.encode("utf-8")).hexdigest()

    def get(self, key: str):
        with self._lock:
            if key not in self._store:
                return None
            self._store.move_to_end(key)
            return self._store[key]

    def put(self, key: str, value) -> None:
        with self._lock:
            if key in self._store:
                self._store.move_to_end(key)
            self._store[key] = value
            while len(self._store) > self.max_size:
                self._store.popitem(last=False)

    def delete(self, key: str) -> bool:
        with self._lock:
            return self._store.pop(key, None) is not None

    def __len__(self) -> int:
        with self._lock:
            return len(self._store)


class VEJIEngine:
    def __init__(self) -> None:
        self.model = None
        self.cache = CompiledStateCache(MAX_CACHED_STATES)
        self._lock = threading.Lock()
        self._loaded_at: Optional[float] = None
        self._config: Dict[str, Any] = {}

    # ------------------------------------------------------------------ load
    def load(self) -> None:
        from huggingface_hub import snapshot_download

        model_dir = Path(MODEL_DIR)
        model_dir.mkdir(parents=True, exist_ok=True)

        # snapshot_download is idempotent — already-cached files are not
        # re-fetched. We pull *.py so veji.py lands on disk and can be
        # imported without a separate raw-file fetch.
        if not (model_dir / "veji_head.pt").exists():
            logger.info("Downloading %s into %s", MODEL_ID, model_dir)
            snapshot_download(
                repo_id=MODEL_ID,
                local_dir=str(model_dir),
                local_dir_use_symlinks=False,
                allow_patterns=["*.py", "*.json", "*.pt"],
            )

        if str(model_dir) not in sys.path:
            sys.path.insert(0, str(model_dir))

        from veji import load_model  # noqa: E402

        logger.info("Loading VEJI-V2 (device=%s, encoder_fallback=%s)", DEVICE, ENCODER_FALLBACK)
        t0 = time.monotonic()

        self.model = load_model(
            model_dir_or_repo=str(model_dir),
            device=DEVICE,
            allow_encoder_fallback=ENCODER_FALLBACK,
        )

        self._loaded_at = time.monotonic()
        logger.info(
            "VEJI-V2 loaded in %.1fs (encoder backend=%s)",
            self._loaded_at - t0,
            getattr(self.model.encoder, "backend", "unknown"),
        )

        cfg_path = model_dir / "config.json"
        if cfg_path.exists():
            try:
                self._config = json.loads(cfg_path.read_text())
            except Exception:
                logger.warning("config.json present but unreadable; ignoring.")

    # ------------------------------------------------------------- inference
    def compile_state(self, state: str) -> Tuple[str, bool]:
        if len(state) > MAX_CONTEXT_CHARS:
            raise ValueError(
                f"state length {len(state)} exceeds configured maximum "
                f"{MAX_CONTEXT_CHARS} characters"
            )

        key = CompiledStateCache.key_for(state)

        with self._lock:
            # Check cache inside the lock to avoid TOCTOU: two concurrent
            # calls with the same state would both miss an outside check
            # and redundantly compile.
            cached = self.cache.get(key)
            if cached is not None:
                return key, True

            compiled = self.model.compile_state(state)
            self.cache.put(key, compiled)

        return key, False

    def decide_compiled(
        self, state_id: str, questions: List[dict], abstain_threshold: Optional[float]
    ) -> List[dict]:
        compiled = self.cache.get(state_id)
        if compiled is None:
            raise KeyError(state_id)
        with self._lock:
            return self.model.decide_compiled(
                compiled, questions, abstain_threshold=abstain_threshold
            )

    def decide(
        self, state: str, questions: List[dict], abstain_threshold: Optional[float]
    ) -> List[dict]:
        with self._lock:
            return self.model.decide(
                state, questions, abstain_threshold=abstain_threshold
            )

    # ------------------------------------------------------------------ info
    def info(self) -> Dict[str, Any]:
        return {
            "model_id": MODEL_ID,
            "device": DEVICE,
            "loaded_at_unix": self._loaded_at,
            "encoder_backend": getattr(self.model.encoder, "backend", None)
            if self.model
            else None,
            "cached_states": len(self.cache),
            "cache_capacity": self.cache.max_size,
            "model_config_json": self._config,
            "version": "1.0.0",
        }


# Single module-level instance shared by the FastAPI app.
engine = VEJIEngine()
PYEOF
log_success "Wrote app/engine.py"

# =============================================================================
# 10. app/main.py — FastAPI application
# =============================================================================
write_file "$INSTALL_DIR/app/main.py" <<'PYEOF'
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

from .engine import ABSTAIN_THRESHOLD, engine
from .schemas import (
    CompileRequest,
    CompileResponse,
    DecideRequest,
    DecideRequestCompiled,
    DecideResponse,
    HealthResponse,
    InfoResponse,
)

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("veji.api")

REQUESTS = Counter("veji_requests_total", "Requests by endpoint and status", ["endpoint", "status"])
LATENCY = Histogram(
    "veji_request_duration_seconds",
    "End-to-end request duration",
    ["endpoint"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120],
)
CACHED_STATES = Gauge("veji_cached_states", "Compiled states currently held in memory")
COMPILE_DURATION = Histogram(
    "veji_compile_duration_seconds",
    "State compilation time",
    buckets=[0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
)
DECISION_DURATION = Histogram(
    "veji_decision_duration_seconds",
    "Per-call decide time",
    ["endpoint"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30],
)
QUESTIONS_PER_REQUEST = Histogram(
    "veji_questions_per_request",
    "Questions per decide call",
    buckets=[1, 2, 4, 8, 16, 32, 64, 128, 256, 512],
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting VEJI-V2 API; loading model...")
    engine.load()
    CACHED_STATES.set(len(engine.cache))
    logger.info("Model ready.")
    yield
    logger.info("Shutting down.")


app = FastAPI(
    title="VEJI-V2 Decision API",
    version="1.0.0",
    description=(
        "HTTP wrapper around loaiabdalslam/VEJI-V2 — a compact typed-decision "
        "model. NOT a generative LLM: it selects among supplied options."
    ),
    lifespan=lifespan,
)


def _effective_threshold(request_threshold: Optional[float]) -> Optional[float]:
    return request_threshold if request_threshold is not None else ABSTAIN_THRESHOLD


# --------------------------------------------------------------------- health
@app.get("/health", response_model=HealthResponse, tags=["system"])
async def health():
    info = engine.info()
    return HealthResponse(
        status="ok" if engine.model is not None else "loading",
        model_loaded=engine.model is not None,
        device=info["device"],
        encoder_backend=info["encoder_backend"],
        cached_states=len(engine.cache),
        version="1.0.0",
    )


@app.get("/v1/info", response_model=InfoResponse, tags=["system"])
async def info():
    return InfoResponse(**engine.info())


# -------------------------------------------------------------------- compile
@app.post("/v1/compile", response_model=CompileResponse, tags=["state"])
async def compile_state(req: CompileRequest):
    t0 = time.monotonic()
    try:
        state_id, was_cached = engine.compile_state(req.state)
    except ValueError as e:
        REQUESTS.labels(endpoint="compile", status="rejected").inc()
        raise HTTPException(status_code=422, detail=str(e))
    except Exception:
        REQUESTS.labels(endpoint="compile", status="error").inc()
        logger.exception("compile failed")
        raise HTTPException(status_code=500, detail="Internal error during state compilation.")

    elapsed = time.monotonic() - t0
    if not was_cached:
        COMPILE_DURATION.observe(elapsed)
    CACHED_STATES.set(len(engine.cache))
    REQUESTS.labels(endpoint="compile", status="ok").inc()

    return CompileResponse(
        state_id=state_id,
        was_cached=was_cached,
        char_count=len(req.state),
        compile_time_s=elapsed,
        cached_states=len(engine.cache),
    )


@app.delete("/v1/state/{state_id}", tags=["state"])
async def evict_state(state_id: str):
    removed = engine.cache.delete(state_id)
    CACHED_STATES.set(len(engine.cache))
    return {"state_id": state_id, "removed": removed}


# --------------------------------------------------------------------- decide
@app.post("/v1/decide", response_model=DecideResponse, tags=["decision"])
async def decide(req: DecideRequest):
    """
    One-shot: compiles the state, answers all questions, discards the state.
    For repeated questions against the same state, prefer /v1/compile then
    /v1/decide/compiled — that is the intended performance path.
    """
    t0 = time.monotonic()
    threshold = _effective_threshold(req.abstain_threshold)
    try:
        results = engine.decide(
            req.state, [q.model_dump() for q in req.questions], threshold
        )
    except Exception:
        REQUESTS.labels(endpoint="decide", status="error").inc()
        logger.exception("decide failed")
        raise HTTPException(status_code=500, detail="Internal error during decision.")

    elapsed = time.monotonic() - t0
    LATENCY.labels(endpoint="decide").observe(elapsed)
    DECISION_DURATION.labels(endpoint="decide").observe(elapsed)
    QUESTIONS_PER_REQUEST.observe(len(req.questions))
    REQUESTS.labels(endpoint="decide", status="ok").inc()

    return DecideResponse(
        results=results,
        question_count=len(req.questions),
        abstain_threshold=threshold,
        decision_time_s=elapsed,
        throughput_qps=(len(req.questions) / elapsed) if elapsed > 0 else None,
    )


@app.post("/v1/decide/compiled", response_model=DecideResponse, tags=["decision"])
async def decide_compiled(req: DecideRequestCompiled):
    """
    Reuse a state previously created with /v1/compile. Skips the compile step
    entirely — this is what the model card calls the intended performance path.
    """
    t0 = time.monotonic()
    threshold = _effective_threshold(req.abstain_threshold)
    try:
        results = engine.decide_compiled(
            req.state_id, [q.model_dump() for q in req.questions], threshold
        )
    except KeyError:
        REQUESTS.labels(endpoint="decide_compiled", status="unknown_state").inc()
        raise HTTPException(
            status_code=404,
            detail=(
                f"state_id {req.state_id!r} is unknown or has been evicted. "
                "Re-run /v1/compile to repopulate it."
            ),
        )
    except Exception:
        REQUESTS.labels(endpoint="decide_compiled", status="error").inc()
        logger.exception("decide_compiled failed")
        raise HTTPException(status_code=500, detail="Internal error during compiled decision.")

    elapsed = time.monotonic() - t0
    LATENCY.labels(endpoint="decide_compiled").observe(elapsed)
    DECISION_DURATION.labels(endpoint="decide_compiled").observe(elapsed)
    QUESTIONS_PER_REQUEST.observe(len(req.questions))
    REQUESTS.labels(endpoint="decide_compiled", status="ok").inc()

    return DecideResponse(
        results=results,
        question_count=len(req.questions),
        abstain_threshold=threshold,
        decision_time_s=elapsed,
        throughput_qps=(len(req.questions) / elapsed) if elapsed > 0 else None,
    )


# -------------------------------------------------------------------- metrics
@app.get("/metrics", tags=["system"])
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
PYEOF
log_success "Wrote app/main.py"

# =============================================================================
# 11. Helper scripts
# =============================================================================
write_file "$INSTALL_DIR/scripts/smoke-test.sh" <<'SMOKEEOF'
#!/usr/bin/env bash
# Smoke test using the example from the model card.
set -euo pipefail
PORT="${VEJI_PORT:-5090}"
BASE="http://127.0.0.1:${PORT}"

echo "--- /health ---"
curl -sf "$BASE/health" | python3 -m json.tool

echo
echo "--- /v1/compile (long state, compiled once) ---"
STATE='Customer Ahmed requested a refund. Policy: refund requests go to billing. The purchase was 3 days ago. Additional context: the customer has been with us for 4 years and has no prior refund requests. The order ID is #44921. The refund amount is 249.99 USD.'
COMPILE=$(curl -sf -X POST "$BASE/v1/compile" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1]}))' "$STATE")")
echo "$COMPILE" | python3 -m json.tool

STATE_ID=$(echo "$COMPILE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state_id"])')

echo
echo "--- /v1/decide/compiled (reuse) ---"
curl -sf -X POST "$BASE/v1/decide/compiled" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({
    "state_id": sys.argv[1],
    "questions": [{
      "id": "route",
      "type": "choice",
      "semantic_type": "route",
      "instruction": "Which team should handle this?",
      "options": ["sales", "billing", "support", "legal"]
    }]
  }))' "$STATE_ID")" | python3 -m json.tool

echo
echo "--- /v1/decide (one-shot) ---"
curl -sf -X POST "$BASE/v1/decide" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({
    "state": sys.argv[1],
    "questions": [{
      "id": "route",
      "type": "choice",
      "instruction": "Which team should handle this?",
      "options": ["sales", "billing", "support", "legal"]
    }]
  }))' "$STATE")" | python3 -m json.tool

echo
echo "Smoke test complete."
SMOKEEOF
chmod +x "$INSTALL_DIR/scripts/smoke-test.sh"

write_file "$INSTALL_DIR/scripts/health-check.sh" <<'HEOF'
#!/usr/bin/env bash
docker exec veji-api curl -sf http://localhost:8000/health | python3 -m json.tool \
  || echo "veji-api is not responding"
HEOF
chmod +x "$INSTALL_DIR/scripts/health-check.sh"

write_file "$INSTALL_DIR/scripts/logs.sh" <<LEOF
#!/usr/bin/env bash
docker compose --project-directory ${INSTALL_DIR} logs -f "\$@"
LEOF
chmod +x "$INSTALL_DIR/scripts/logs.sh"

log_success "Wrote helper scripts"

# =============================================================================
# 12. Build + start
# =============================================================================
cd "$INSTALL_DIR"

BUILD_TAG="veji-api:$(date -u +%Y%m%d-%H%M%S)"
log_info "Building image (tag: ${BUILD_TAG}; first build pulls CPU torch + sentence-transformers; can take several minutes)..."
docker compose build
docker tag "$(docker compose images -q veji-api 2>/dev/null | head -1)" "$BUILD_TAG" 2>/dev/null || true
log_success "Image built and tagged as ${BUILD_TAG}."

log_info "Starting container..."
docker compose up -d

log_info "Waiting for /health to report model_loaded=true (up to 10 minutes for first-run encoder download)..."
ATTEMPTS=120
for i in $(seq 1 "$ATTEMPTS"); do
  BODY=$(curl -sf "http://127.0.0.1:${VEJI_PORT}/health" 2>/dev/null) || { sleep 5; continue; }
  if echo "$BODY" | grep -q '"model_loaded":true'; then
    log_success "API is up and the model is loaded."
    break
  fi
  if [[ "$i" == "$ATTEMPTS" ]]; then
    log_error "Model did not load within the wait window."
    log_error "Check logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs veji-api"
    exit 1
  fi
  sleep 5
done

# =============================================================================
# 13. Summary
# =============================================================================
echo ""
log_success "VEJI-V2 Decision API is running."
echo "  Local URL:    http://127.0.0.1:${VEJI_PORT}"
echo "  Swagger:      http://127.0.0.1:${VEJI_PORT}/docs"
echo "  Health:       http://127.0.0.1:${VEJI_PORT}/health"
echo "  Metrics:      http://127.0.0.1:${VEJI_PORT}/metrics"
echo ""
log_info "Nginx Proxy Manager Configuration"
echo "  Domain:               ${DOMAIN}"
echo "  Forward Hostname/IP:  veji-api"
echo "  Forward Port:         8000"
echo "  Scheme:               http"
echo "  Enable:               Block Common Exploits, Websockets Support, Force SSL, HTTP/2, HSTS"
echo ""
log_info "Endpoints"
echo "  POST /v1/compile             — compile a state once, get a state_id"
echo "  POST /v1/decide/compiled     — questions against a pre-compiled state_id"
echo "  POST /v1/decide              — one-shot: state + questions (compiles internally)"
echo "  GET  /v1/info                — model metadata + cache stats"
echo "  DEL  /v1/state/{state_id}    — evict a cached state"
echo ""
echo "Run the smoke test:"
echo "  $INSTALL_DIR/scripts/smoke-test.sh"
echo ""
log_warn "PRODUCTION READINESS (per the model card's own gate):"
echo "  Accuracy 82.95% (target >=85%)        FAIL"
echo "  ECE-10 0.0663 (target <=0.03)         FAIL"
echo "  Min family accuracy 18.18% (>=80%)    FAIL"
echo "  The author states this checkpoint is NOT a production candidate."
echo "  Weak families include code_python_output (20-50%), forecast_bucket"
echo "  (50-70%), data_quality (50-70%), contradiction (72.73%)."
echo "  Treat outputs as advisory and validate against your own calibration set"
echo "  before gating any real workflow on them."