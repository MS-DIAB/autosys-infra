#!/usr/bin/env bash
# =============================================================================
# S32_STT-API-v2.sh
# -----------------------------------------------------------------------------
# Installs the AutoSys STT API: dual Nemotron 3.5 ASR engines (Arabic
# dialect-tuned + multilingual), a FastAPI router (VAD + LID + dialect gate +
# confidence gate), and a permanently-warm faster-whisper fallback.
#
# Usage:
#   ./S32_STT-API-v2.sh              # install / idempotent re-run
#   ./S32_STT-API-v2.sh --force      # regenerate all generated files from scratch
#   ./S32_STT-API-v2.sh --down       # stop and remove the stack (keeps models/logs)
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration --------------------------------
INSTALL_DIR="${STT_INSTALL_DIR:-/opt/stt-api}"
NETWORK_NAME="${AUTOSYS_NETWORK:-proxy-network}"
DOMAIN="${STT_DOMAIN:-stt.${BASE_DOMAIN:-example.com}}"
TIMEZONE="${STT_TIMEZONE:-${TIMEZONE:-UTC}}"
INTERNAL_NETWORK_NAME="${STT_INTERNAL_NETWORK:-stt-internal}"

ROUTER_PORT="${STT_ROUTER_PORT:-8090}"

CONCURRENCY_ARABIC="${STT_CONCURRENCY_ARABIC:-6}"
CONCURRENCY_MULTI="${STT_CONCURRENCY_MULTI:-2}"

ARABIC_MEM_LIMIT="${STT_ARABIC_MEM_LIMIT:-1.5g}"
MULTI_MEM_LIMIT="${STT_MULTI_MEM_LIMIT:-1.5g}"
WHISPER_MEM_LIMIT="${STT_WHISPER_MEM_LIMIT:-1.2g}"
ROUTER_MEM_LIMIT="${STT_ROUTER_MEM_LIMIT:-512m}"

VAD_MIN_UTTERANCE_MS="${STT_VAD_MIN_MS:-99999}"
DIALECT_GULF_THRESHOLD="${STT_DIALECT_GULF_THRESHOLD:-0.55}"
DIALECT_OTHER_THRESHOLD="${STT_DIALECT_OTHER_THRESHOLD:-0.85}"
CONFIDENCE_THRESHOLD="${STT_CONFIDENCE_THRESHOLD:-0.90}"
CIRCUIT_BREAKER_EXTRA_MS="${STT_CIRCUIT_BREAKER_EXTRA_MS:-1500}"
NEMOTRON_P95_MS="${STT_NEMOTRON_P95_MS:-2500}"

# 'small' (was 'medium' in S31) -- the fallback has to return inside the
# circuit-breaker budget above (P95 + 1.5s), and medium-int8 on CPU was
# measured at ~22x real-time in production, i.e. ~48s for a 2s clip. Small
# is roughly 3x faster on the same hardware.
WHISPER_MODEL_SIZE="${STT_WHISPER_MODEL_SIZE:-small}"
WHISPER_COMPUTE_TYPE="${STT_WHISPER_COMPUTE_TYPE:-int8}"
# 0 = let faster-whisper pick (typically min(4, cpu_count)). Set explicitly
# if the container is under a CPU quota faster-whisper can't see.
WHISPER_CPU_THREADS="${STT_WHISPER_CPU_THREADS:-0}"

ENGINE_MODEL_RELEASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2"

FORCE=false
ACTION="up"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --down) ACTION="down" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ------------------------------ Colors / logging -----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
trap 'log_error "Install failed at line $LINENO. See output above."' ERR

# write_file <path> : reads heredoc from stdin, skips if file exists unless --force
write_file() {
  local path="$1"
  if [[ -f "$path" && "$FORCE" != true ]]; then
    log_info "Skipping existing file: $path (use --force to regenerate)"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  log_success "Wrote $path"
}

# =============================================================================
# 0. Teardown path
# =============================================================================
if [[ "$ACTION" == "down" ]]; then
  log_info "Stopping STT API stack..."
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    (cd "$INSTALL_DIR" && docker compose down)
    log_success "Stack stopped. Models and logs left in place under $INSTALL_DIR."
  else
    log_warn "No docker-compose.yml found at $INSTALL_DIR -- nothing to stop."
  fi
  exit 0
fi

# =============================================================================
# 0b. Hugging Face token (optional, interactive)
# =============================================================================
# Only prompts when there's no value already (via STT_HF_TOKEN) and the
# .env doesn't already exist yet or --force was passed -- otherwise a
# non-interactive re-run (cron, CI, or a plain re-run to pick up other
# changes) would hang waiting for input that isn't coming. Unlike the
# Cloudflare tunnel token, this one is optional: most of this stack (the
# public multilingual model, Whisper's default public weights) works fine
# without it. It's only needed for gated/private HF repos or to avoid
# anonymous rate limits.
NEEDS_ENV_WRITE=true
[[ -f "$INSTALL_DIR/.env" && "$FORCE" != true ]] && NEEDS_ENV_WRITE=false

if [[ -z "${STT_HF_TOKEN:-}" && "$NEEDS_ENV_WRITE" == true && -t 0 ]]; then
  echo
  echo "Hugging Face token (optional -- press Enter to skip)."
  echo "Only needed for gated/private model repos or to avoid anonymous rate limits."
  read -rsp "HF token: " STT_HF_TOKEN
  echo
  if [[ -n "$STT_HF_TOKEN" ]]; then
    log_success "Token received."
  else
    log_info "No token entered -- continuing without one."
  fi
fi

# =============================================================================
# 1. Pre-flight checks
# =============================================================================
log_info "Running pre-flight checks..."

command -v docker >/dev/null 2>&1 || { log_error "docker is not installed."; exit 1; }
docker compose version >/dev/null 2>&1 || { log_error "docker compose plugin is not available."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl is required."; exit 1; }

AVAIL_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
REQUIRED_MEM_MB=$(( 512 + 1536 + 1536 + 1200 + 500 )) # router + arabic + multi + whisper + headroom
if [[ "${AVAIL_MEM_MB:-0}" -lt "$REQUIRED_MEM_MB" ]]; then
  log_warn "Available memory (${AVAIL_MEM_MB:-unknown}MB) is below the recommended ${REQUIRED_MEM_MB}MB."
  log_warn "The stack may still start, but expect eviction/OOM risk under concurrent load."
else
  log_success "Memory check passed (${AVAIL_MEM_MB}MB available)."
fi

AVAIL_DISK_GB=$(df -Pm "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
if [[ "${AVAIL_DISK_GB:-0}" -lt 10 ]]; then
  log_warn "Less than 10GB free disk at $(dirname "$INSTALL_DIR") -- model downloads may fail."
else
  log_success "Disk space check passed (${AVAIL_DISK_GB}GB available)."
fi

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log_success "Docker network '$NETWORK_NAME' already exists."
else
  log_info "Creating docker network '$NETWORK_NAME'..."
  docker network create "$NETWORK_NAME"
  log_success "Network created."
fi

for p in "$ROUTER_PORT"; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; then
    log_warn "Port $p already appears to be in use on this host."
  fi
done

# =============================================================================
# 2. Directory scaffold
# =============================================================================
log_info "Scaffolding directories under $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"/{router/app,engine/app,whisper-fallback/app,models/arabic,models/multilingual,models/whisper-cache,logs/audit,scripts}
log_success "Directories ready."

# =============================================================================
# 3. .env
# =============================================================================
write_file "$INSTALL_DIR/.env" <<EOF
NETWORK_NAME=${NETWORK_NAME}
INTERNAL_NETWORK_NAME=${INTERNAL_NETWORK_NAME}
DOMAIN=${DOMAIN}
TIMEZONE=${TIMEZONE}

ROUTER_PORT=${ROUTER_PORT}

CONCURRENCY_ARABIC=${CONCURRENCY_ARABIC}
CONCURRENCY_MULTI=${CONCURRENCY_MULTI}

VAD_MIN_UTTERANCE_MS=${VAD_MIN_UTTERANCE_MS}
DIALECT_GULF_THRESHOLD=${DIALECT_GULF_THRESHOLD}
DIALECT_OTHER_THRESHOLD=${DIALECT_OTHER_THRESHOLD}
CONFIDENCE_THRESHOLD=${CONFIDENCE_THRESHOLD}
CIRCUIT_BREAKER_TIMEOUT_MS=$(( NEMOTRON_P95_MS + CIRCUIT_BREAKER_EXTRA_MS ))
MAX_AUDIO_MB=${STT_MAX_AUDIO_MB:-10}

# LID round-trip is skipped by default: the multilingual engine's
# /transcribe currently always returns detected_language="unknown" (it
# doesn't perform real language ID yet -- see engine/app/server.py and
# stt-api-spec.md 3.1). Until that's real, calling it adds ~1s of latency
# per request that has no lang_hint and can never route anywhere but the
# multilingual engine anyway. Set to "true" once the engine's detected
# language field is trustworthy.
LID_ENABLED=false

# Only needed for gated/private Hugging Face repos, or to avoid anonymous
# rate limits on the Whisper fallback's model download. huggingface_hub
# reads this env var automatically -- no code change needed to use it.
# Leave blank for the default public whisper download.
HF_TOKEN=${STT_HF_TOKEN:-}

ARABIC_ENGINE_URL=http://stt-arabic-engine:8000
MULTI_ENGINE_URL=http://stt-multilingual-engine:8000
WHISPER_ENGINE_URL=http://stt-whisper-fallback:8000

WHISPER_MODEL_SIZE=large-v3
WHISPER_COMPUTE_TYPE=int8

DIALECT_GATE_MODEL_PATH=/models/dialect_gate.onnx

# Stays false until the retention/consent legal sign-off from spec section 5
# is complete (see stt-api-spec.md) -- flip to true only after that.
AUDIT_ENABLED=false
AUDIT_LOG_DIR=/logs
AUDIT_RETENTION_DAYS=30
EOF
chmod 600 "$INSTALL_DIR/.env"

# =============================================================================
# 4. docker-compose.yml
# =============================================================================
write_file "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  stt-router:
    build: ./router
    container_name: stt-router
    env_file: .env
    environment:
      - TZ=${TIMEZONE}
    # Localhost-only, matching the translate-api convention -- the public
    # path is Cloudflare -> NPM -> stt-router:8000 over ${NETWORK_NAME},
    # not a directly published host port. This is for local debugging only.
    ports:
      - "127.0.0.1:${ROUTER_PORT}:8000"
    volumes:
      - ./logs/audit:/logs
      - ./models:/models:ro
    networks: [${INTERNAL_NETWORK_NAME}, ${NETWORK_NAME}]
    mem_limit: ${ROUTER_MEM_LIMIT}
    depends_on:
      stt-arabic-engine:
        condition: service_healthy
      stt-multilingual-engine:
        condition: service_healthy
      stt-whisper-fallback:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 10s
    restart: unless-stopped

  stt-arabic-engine:
    build: ./engine
    container_name: stt-arabic-engine
    environment:
      - TZ=${TIMEZONE}
      - MODEL_DIR=/models/arabic
      - ENGINE_NAME=arabic
      - MAX_CONCURRENCY=${CONCURRENCY_ARABIC}
      - ALLOW_STUB=true   # no public checkpoint exists yet -- see spec 3.2/3.3
    volumes:
      - ./models/arabic:/models/arabic:ro
    # No host port -- only stt-router (on the same internal network) ever
    # calls this directly, matching the tts-api-ar/tts-api-en pattern.
    networks: [${INTERNAL_NETWORK_NAME}]
    mem_limit: ${ARABIC_MEM_LIMIT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 20s
    restart: unless-stopped

  stt-multilingual-engine:
    build: ./engine
    container_name: stt-multilingual-engine
    environment:
      - TZ=${TIMEZONE}
      - MODEL_DIR=/models/multilingual
      - ENGINE_NAME=multilingual
      - MAX_CONCURRENCY=${CONCURRENCY_MULTI}
      - ALLOW_STUB=false  # this one is auto-downloaded during setup -- must load for real
    volumes:
      - ./models/multilingual:/models/multilingual:ro
    networks: [${INTERNAL_NETWORK_NAME}]
    mem_limit: ${MULTI_MEM_LIMIT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 20s
    restart: unless-stopped

  stt-whisper-fallback:
    build: ./whisper-fallback
    container_name: stt-whisper-fallback
    environment:
      - TZ=${TIMEZONE}
      - WHISPER_MODEL_SIZE=${WHISPER_MODEL_SIZE}
      - WHISPER_COMPUTE_TYPE=${WHISPER_COMPUTE_TYPE}
      - WHISPER_CPU_THREADS=${WHISPER_CPU_THREADS}
      - HF_TOKEN=\${HF_TOKEN}
    volumes:
      - ./models/whisper-cache:/root/.cache/huggingface
    networks: [${INTERNAL_NETWORK_NAME}]
    mem_limit: ${WHISPER_MEM_LIMIT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped
    # Deliberately no TTL/idle-unload here -- must stay warm per spec section 3.4.

networks:
  ${INTERNAL_NETWORK_NAME}:
    driver: bridge
  ${NETWORK_NAME}:
    external: true
EOF

# =============================================================================
# 5. Router service
# =============================================================================
write_file "$INSTALL_DIR/router/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
python-multipart==0.0.9
numpy==1.26.4
onnxruntime==1.19.2
EOF

write_file "$INSTALL_DIR/router/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
# ffmpeg is what lets /v1/transcribe accept any audio container/codec
# (mp3, m4a/aac, ogg/opus, flac, webm, amr, ...), not just raw 16kHz mono
# PCM16 -- the router shells out to it to normalize every upload before it
# ever reaches the ASR engines (see transcode.py).
RUN apt-get update && apt-get install -y --no-install-recommends curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

write_file "$INSTALL_DIR/router/app/vad.py" <<'EOF'
"""
Lightweight RMS-energy VAD with a hard minimum-utterance floor.

This intentionally avoids an extra model download to keep the router image
small. If accuracy on quiet/noisy audio turns out to be insufficient, swap
this for sherpa-onnx's built-in Silero VAD wrapper (same runtime already used
by the ASR engines) -- see https://k2-fsa.github.io/sherpa/onnx/ for the
current VAD model asset path before wiring it in.
"""
import numpy as np

FRAME_MS = 20


def _pcm16_to_float(audio_bytes: bytes) -> np.ndarray:
    return np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0


def trim_silence(audio_bytes: bytes, sample_rate: int, min_utterance_ms: int) -> bytes:
    """Trim leading/trailing silence. Falls back to raw audio if the trimmed
    result would be shorter than min_utterance_ms, per spec 3.1."""
    samples = _pcm16_to_float(audio_bytes)
    if samples.size == 0:
        return audio_bytes

    frame_len = max(int(sample_rate * FRAME_MS / 1000), 1)
    n_frames = max(len(samples) // frame_len, 1)
    frames = samples[: n_frames * frame_len].reshape(n_frames, frame_len)
    energy = np.sqrt(np.mean(frames ** 2, axis=1))

    if energy.size == 0:
        return audio_bytes

    # Threshold anchored to a noise-floor estimate (a low percentile of frame
    # energy), not to the clip's single loudest frame. A peak-relative
    # threshold misclassifies quieter-but-real speech as silence whenever a
    # clip has a loud onset followed by a softer tail (e.g. an exclamation
    # that trails off) -- the tail never crosses e.g. 8% of that peak and
    # gets trimmed away along with actual silence. Anchoring to the noise
    # floor instead only filters background quiet, regardless of how loud
    # the loudest moment in the clip was.
    noise_floor = np.percentile(energy, 20)
    threshold = max(noise_floor * 2.5, energy.max() * 0.03, 1e-4)
    voiced = np.where(energy > threshold)[0]

    if voiced.size == 0:
        return audio_bytes  # nothing detected as voiced -- let the engine decide

    start = voiced[0] * frame_len
    end = min((voiced[-1] + 1) * frame_len, len(samples))
    trimmed = samples[start:end]

    trimmed_ms = (len(trimmed) / sample_rate) * 1000
    if trimmed_ms < min_utterance_ms:
        return audio_bytes

    trimmed_int16 = (trimmed * 32768.0).clip(-32768, 32767).astype(np.int16)
    return trimmed_int16.tobytes()
EOF

write_file "$INSTALL_DIR/router/app/dialect_gate.py" <<'EOF'
"""
Dialect gate: 3-bucket classifier (gulf / other / unsure) for Arabic audio
only. The router must not call this for audio the LID step didn't already
flag as Arabic -- see spec section 2 (LID before dialect gate).

No trained classifier ships with this installer (spec section 3.2, phase 1/2
is a build task, not an install task). Until DIALECT_GATE_MODEL_PATH points
at a real ONNX export, this always returns "unsure" with confidence 0.0,
which safely routes everything to the multilingual engine rather than
mis-serving dialects the tuned engine was never trained on.
"""
import os
import logging

logger = logging.getLogger("dialect_gate")
_warned = False

MODEL_PATH = os.environ.get("DIALECT_GATE_MODEL_PATH", "/models/dialect_gate.onnx")
GULF_THRESHOLD = float(os.environ.get("DIALECT_GULF_THRESHOLD", "0.55"))
OTHER_THRESHOLD = float(os.environ.get("DIALECT_OTHER_THRESHOLD", "0.85"))

_session = None
if os.path.exists(MODEL_PATH):
    import onnxruntime as ort
    _session = ort.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])


def classify(audio_bytes: bytes) -> tuple[str, float]:
    global _warned
    if _session is None:
        if not _warned:
            logger.warning(
                "No dialect gate model at %s -- defaulting every request to "
                "'unsure' (routes to multilingual engine). Train and drop in "
                "an ONNX classifier per spec section 3.2 before relying on "
                "the Arabic engine.", MODEL_PATH,
            )
            _warned = True
        return "unsure", 0.0

    # TODO: wire up real feature extraction + inference once the classifier
    # exists. Expected output: softmax over [gulf, other, unsure].
    # probs = _session.run(...)
    # gulf, other, unsure = probs
    # if gulf > GULF_THRESHOLD: return "gulf", gulf
    # if other > OTHER_THRESHOLD: return "other", other
    # return "unsure", unsure
    return "unsure", 0.0
EOF

write_file "$INSTALL_DIR/router/app/confidence_gate.py" <<'EOF'
"""
Confidence gate: combines acoustic score with a length-normalized
log-likelihood to decide whether to trust the primary transcript or fall
back to Whisper. Acoustic confidence alone is unreliable for CTC/RNNT
exports (they can be overconfident on hallucinated text) -- see spec
section 3.4.

THRESHOLD is a placeholder (0.60) and MUST be replaced with the value
derived from the 1,000-utterance calibration set (F0.5-optimized) before
this gates anything in production. Shipping on a guessed number defeats the
purpose of building the calibration set at all.
"""
import os

THRESHOLD = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.90"))


def evaluate(avg_logprob: float, text_len: int) -> tuple[bool, float]:
    """Returns (is_confident, combined_score). combined_score is a rough
    proxy pending the real perplexity-based calibration."""
    if text_len == 0:
        return False, 0.0
    # Rough proxy: normalized logprob squashed into [0, 1]. Replace with the
    # calibrated score + perplexity heuristic from spec 3.4.
    score = max(0.0, min(1.0, (avg_logprob + 1.0)))
    return score >= THRESHOLD, score
EOF

write_file "$INSTALL_DIR/router/app/audit_log.py" <<'EOF'
"""
Async, off-hot-path audit logger. Writes one JSON line per request to
/logs/audit/YYYY-MM-DD.jsonl. Respects an X-Audit-Opt-Out header.

NOTE: disk-write is a hard release blocker per spec section 5 until legal
sign-off on retention/anonymization is complete. AUDIT_ENABLED defaults to
"false" here on purpose -- flip it only after that sign-off.
"""
import os
import json
import uuid
import asyncio
from datetime import datetime, timezone

AUDIT_ENABLED = os.environ.get("AUDIT_ENABLED", "false").lower() == "true"
LOG_DIR = os.environ.get("AUDIT_LOG_DIR", "/logs")


async def log_request(opted_out: bool, **fields) -> None:
    if not AUDIT_ENABLED or opted_out:
        return

    def _write():
        os.makedirs(LOG_DIR, exist_ok=True)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        path = os.path.join(LOG_DIR, f"{day}.jsonl")
        record = {
            "audio_uuid": str(uuid.uuid4()),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **fields,
        }
        with open(path, "a") as f:
            f.write(json.dumps(record) + "\n")

    await asyncio.to_thread(_write)
EOF

write_file "$INSTALL_DIR/router/app/transcode.py" <<'EOF'
"""
Normalizes any uploaded audio file (whatever container/codec the caller
sent -- wav, mp3, m4a/aac, ogg/opus, flac, webm, amr, ...) into the raw
16kHz mono PCM16 the VAD, dialect gate, and every ASR engine assume.

This is the one place format-handling lives. Everything downstream of
transcode_to_pcm16() keeps treating its input as headerless 16-bit PCM at
TARGET_SAMPLE_RATE -- unchanged from before.
"""
import asyncio
import logging

logger = logging.getLogger("stt-router.transcode")

TARGET_SAMPLE_RATE = 16000


class TranscodeError(Exception):
    """Raised when ffmpeg can't decode the uploaded file (corrupt file,
    unsupported/unrecognized codec, empty upload, etc.)."""


async def transcode_to_pcm16(raw: bytes) -> bytes:
    if not raw:
        raise TranscodeError("empty audio upload")

    # -nostdin: don't let ffmpeg try to read interactive input from the
    #   pipe it doesn't have.
    # -i pipe:0 / -f s16le ... pipe:1: decode whatever container/codec was
    #   sent on stdin, resample+downmix, and stream raw PCM16 out on
    #   stdout -- no temp files, so concurrent requests don't collide.
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0",
        "-f", "s16le", "-acodec", "pcm_s16le",
        "-ac", "1", "-ar", str(TARGET_SAMPLE_RATE),
        "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate(input=raw)

    if proc.returncode != 0 or not stdout:
        err = stderr.decode("utf-8", errors="replace").strip()
        logger.warning("ffmpeg failed to decode upload: %s", err)
        raise TranscodeError(
            err or "ffmpeg could not decode this file (unrecognized or "
                   "corrupt audio)"
        )

    return stdout
EOF

write_file "$INSTALL_DIR/router/app/main.py" <<'EOF'
import os
import re
import time
import asyncio
import logging

import httpx
from fastapi import FastAPI, UploadFile, File, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse

from . import vad, dialect_gate, confidence_gate, audit_log, transcode

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("stt-router")

ARABIC_ENGINE_URL = os.environ["ARABIC_ENGINE_URL"]
MULTI_ENGINE_URL = os.environ["MULTI_ENGINE_URL"]
WHISPER_ENGINE_URL = os.environ["WHISPER_ENGINE_URL"]
VAD_MIN_MS = int(os.environ.get("VAD_MIN_UTTERANCE_MS", "99999"))
CIRCUIT_BREAKER_TIMEOUT_S = int(os.environ.get("CIRCUIT_BREAKER_TIMEOUT_MS", "4000")) / 1000
MAX_AUDIO_BYTES = int(os.environ.get("MAX_AUDIO_MB", "1000")) * 1024 * 1024

# The engine's /transcribe does not currently return a real detected language
# (it always echoes "unknown" -- see engine/app/server.py), so the LID
# round-trip in _quick_lid is a wasted multilingual-engine call that adds
# latency to every request without lang_hint and can never route anywhere but
# the multilingual engine anyway. Skipped by default until LID is real.
LID_ENABLED = os.environ.get("LID_ENABLED", "false").lower() == "true"

# Catches unrendered templating expressions being sent as lang_hint values --
# most commonly an n8n HTTP node whose expression field wasn't evaluated, so
# "$json.lang_hint" or "{{ $json.lang_hint }}" ends up as the literal string.
# Left unchecked, that string gets passed to the engine as lang_hint AND
# echoed back in the response's "language" field, silently mis-labelling
# every request that was supposed to specify a language.
_TEMPLATE_EXPR_RE = re.compile(r"^\s*(?:\$|\{\{)")

app = FastAPI(title="AutoSys STT API")


@app.exception_handler(RequestValidationError)
async def _on_validation_error(request: Request, exc: RequestValidationError):
    """
    FastAPI's default 422 tells the client *which field* was wrong but
    nothing about the shape of what they actually sent. Log the request
    headers once so operators can tell 'missing audio field' apart from
    'wrong content-type' (e.g. JSON body instead of multipart) apart from
    'malformed multipart boundary' without a packet capture.

    Preserves the default response shape ({"detail": [...]}) so clients
    parsing `detail` keep working.
    """
    logger.warning(
        "422 on %s %s: content-type=%r content-length=%r user-agent=%r errors=%s",
        request.method, request.url.path,
        request.headers.get("content-type", ""),
        request.headers.get("content-length", ""),
        request.headers.get("user-agent", ""),
        exc.errors(),
    )
    return JSONResponse(
        {"detail": jsonable_encoder(exc.errors())},
        status_code=422,
    )


@app.on_event("startup")
async def startup_client():
    # One pooled client for the process, not one per request -- avoids
    # re-establishing TCP/keep-alive connections to the engines on every
    # call under concurrent load.
    app.state.http_client = httpx.AsyncClient(
        limits=httpx.Limits(max_connections=50, max_keepalive_connections=20)
    )


@app.on_event("shutdown")
async def shutdown_client():
    await app.state.http_client.aclose()


@app.get("/health")
async def health():
    return {"status": "ok"}


async def _transcribe(client: httpx.AsyncClient, base_url: str, audio: bytes,
                       lang_hint: str | None = None, timeout: float = 30.0) -> dict:
    files = {"audio": ("audio.wav", audio, "audio/wav")}
    params = {"lang_hint": lang_hint} if lang_hint else {}
    resp = await client.post(f"{base_url}/transcribe", files=files, params=params, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


async def _quick_lid(client: httpx.AsyncClient, audio: bytes, sample_rate: int) -> str:
    """
    KNOWN GAP, not yet real language ID -- see spec section 2 (LID before
    dialect gate) and stt-api-spec.md 3.1. The engine's /transcribe does not
    currently perform language detection (see engine/app/server.py), so this
    always returns "unknown", which safely falls through to the multilingual
    engine (the same safe default the spec uses for "Unsure").

    Until that's real (LID_ENABLED=true), the caller skips this entirely --
    a full multilingual-engine round-trip to be told "unknown" every time is
    pure added latency with no routing benefit.
    """
    clip_bytes = 3 * sample_rate * 2  # 3s of 16-bit PCM
    short_clip = audio[:clip_bytes]
    result = await _transcribe(client, MULTI_ENGINE_URL, short_clip)
    return result.get("detected_language", "unknown")


@app.post("/v1/transcribe")
async def transcribe(
    request: Request,
    audio: UploadFile = File(...),
    lang_hint: str | None = Query(default=None),
    x_audit_opt_out: bool = Header(default=False),
):
    request_start = time.monotonic()
    sample_rate = transcode.TARGET_SAMPLE_RATE

    # Reject obvious unrendered template expressions (e.g. n8n sending
    # "$json.lang_hint" literally) instead of silently echoing them back as
    # a "language". Left unchecked, these get passed through to the engine
    # as a lang_hint AND reported as the detected language in the response.
    if lang_hint is not None and _TEMPLATE_EXPR_RE.match(lang_hint):
        logger.warning(
            "Rejecting lang_hint=%r -- looks like an unevaluated template "
            "expression, not a language code. Check the calling workflow "
            "(n8n, curl script, etc.): the expression was probably sent as a "
            "literal string instead of being rendered first.",
            lang_hint,
        )
        return JSONResponse(
            {"error": f"lang_hint looks like an unrendered template "
                      f"expression ({lang_hint!r}). Omit lang_hint entirely "
                      f"to let the router auto-detect, or send a real BCP-47 "
                      f"code like 'ar' or 'en'."},
            status_code=400,
        )

    # Content-Length covers the whole multipart body (boundary overhead
    # included), so it's a conservative upper bound on the audio size -- if
    # it's already over the limit, the audio definitely is too. This lets us
    # reject before touching the body at all. It's not itself trustworthy
    # (a client can lie or omit it), so the streamed read below enforces the
    # real cap regardless of what this header claims.
    content_length = request.headers.get("content-length")
    if content_length:
        if not content_length.isdigit():
            return JSONResponse(
                {"error": f"malformed Content-Length header: {content_length!r}"},
                status_code=400,
            )
        if int(content_length) > MAX_AUDIO_BYTES:
            return JSONResponse(
                {"error": f"request exceeds MAX_AUDIO_MB limit "
                           f"(content-length {content_length} > {MAX_AUDIO_BYTES} bytes)"},
                status_code=413,
            )

    raw_chunks = bytearray()
    while True:
        chunk = await audio.read(1024 * 1024)
        if not chunk:
            break
        raw_chunks.extend(chunk)
        if len(raw_chunks) > MAX_AUDIO_BYTES:
            return JSONResponse(
                {"error": f"audio payload exceeds MAX_AUDIO_MB limit "
                           f"({len(raw_chunks)}+ bytes > {MAX_AUDIO_BYTES} bytes)"},
                status_code=413,
            )
    uploaded = bytes(raw_chunks)

    # uploaded can be any container/codec ffmpeg understands (wav, mp3,
    # m4a/aac, ogg/opus, flac, webm, amr, ...) -- normalize it to
    # headerless 16kHz mono PCM16 here, once, before VAD/LID/dialect-gate
    # and the engines ever see it. They still assume that raw PCM shape
    # and are unchanged.
    try:
        raw = await transcode.transcode_to_pcm16(uploaded)
    except transcode.TranscodeError as exc:
        return JSONResponse(
            {"error": f"could not decode uploaded audio: {exc}"},
            status_code=400,
        )

    trimmed = vad.trim_silence(raw, sample_rate, VAD_MIN_MS)

    client = app.state.http_client

    lang = lang_hint
    if not lang and LID_ENABLED:
        lang = await _quick_lid(client, trimmed, sample_rate)

    dialect = None
    if lang == "ar":
        dialect, dialect_conf = dialect_gate.classify(trimmed)
        target_url = ARABIC_ENGINE_URL if dialect == "gulf" else MULTI_ENGINE_URL
    else:
        target_url = MULTI_ENGINE_URL

    try:
        primary = await _transcribe(client, target_url, trimmed, lang_hint=lang)
        is_confident, score = confidence_gate.evaluate(
            primary.get("avg_logprob", -1.0), len(primary.get("text", ""))
        )
    except Exception as exc:
        # A primary-engine failure (crash, OOM eviction, mid-deploy restart)
        # and a low-confidence result look the same to a caller: "the
        # primary path didn't produce a usable transcript." Whisper is kept
        # permanently warm for exactly this situation, not just for low
        # confidence -- treat both the same way rather than 500ing while a
        # working fallback engine sits right there.
        logger.warning("Primary engine call failed, falling back to Whisper: %r", exc)
        primary = {"text": ""}
        is_confident, score = False, 0.0

    result = primary
    fallback_used = False
    fallback_text = None

    if not is_confident:
        # Budget is the total request time allowed, not a fresh timer --
        # counting from request_start (not "now") is what actually keeps
        # primary_time + fallback_time under the P95 + 1.5s ceiling from
        # spec 3.4, rather than always granting Whisper the full window
        # regardless of how long the primary engine already took.
        remaining = CIRCUIT_BREAKER_TIMEOUT_S - (time.monotonic() - request_start)
        if remaining <= 0.5:
            logger.warning(
                "Skipping Whisper fallback: only %.2fs left in the "
                "circuit-breaker budget after the primary engine call.",
                remaining,
            )
        else:
            try:
                fallback = await asyncio.wait_for(
                    _transcribe(client, WHISPER_ENGINE_URL, trimmed,
                                timeout=remaining),
                    timeout=remaining,
                )
                result = fallback
                fallback_used = True
                fallback_text = fallback.get("text")
            except asyncio.TimeoutError:
                # asyncio.TimeoutError carries no message -- log the budget
                # that was actually available so a too-small
                # CIRCUIT_BREAKER_EXTRA_MS (or a Whisper config too slow to
                # fit) is visible in the logs rather than looking like a
                # silent skip.
                logger.warning(
                    "Whisper fallback exceeded the %.2fs remaining in the "
                    "circuit-breaker budget; returning the primary result. "
                    "If this happens on most low-confidence requests, check "
                    "the whisper-fallback container's per-request latency "
                    "(it logs a real-time factor per call).",
                    remaining,
                )
            except Exception as exc:  # engine error, connection refused, etc.
                logger.warning("Whisper fallback failed: %r", exc)

    await audit_log.log_request(
        opted_out=x_audit_opt_out,
        primary_text=primary.get("text"),
        primary_confidence=score,
        detected_language=lang,
        dialect=dialect,
        fallback_used=fallback_used,
        fallback_text=fallback_text,
    )

    total_s = time.monotonic() - request_start
    logger.info(
        "transcribe: total=%.2fs lang=%s dialect=%s confidence=%.2f "
        "fallback=%s text_len=%d",
        total_s, lang, dialect, score, fallback_used,
        len(result.get("text", "")),
    )

    return JSONResponse({
        "text": result.get("text", ""),
        "language": lang,
        "dialect": dialect,
        "confidence": score,
        "fallback_used": fallback_used,
    })
EOF

# =============================================================================
# 6. Shared ASR engine service (arabic + multilingual use the same image)
# =============================================================================
write_file "$INSTALL_DIR/engine/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
python-multipart==0.0.9
numpy==1.26.4
# 1.10.30 does not exist on PyPI and predates Nemotron 3.5 support anyway --
# the model requires sherpa-onnx >=1.13.4 (the version its release package
# was built against). 1.13.7 is pinned here because it was the version
# actually used to load and decode with the real downloaded model files.
sherpa-onnx==1.13.7
EOF

write_file "$INSTALL_DIR/engine/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

write_file "$INSTALL_DIR/engine/app/server.py" <<'EOF'
"""
Shared sherpa-onnx transducer server. Loaded model depends only on MODEL_DIR
-- the same image runs both the Arabic and multilingual engines, pointed at
different model directories via docker-compose.

Expects MODEL_DIR to contain a standard sherpa-onnx streaming-transducer
layout: encoder.onnx, decoder.onnx, joiner.onnx, tokens.txt. The public
multilingual Nemotron 3.5 package matches this layout; the Arabic
dialect-tuned checkpoint must be exported to the same layout by whoever
trains it (see stt-api-spec.md section 3.3 / 3.2 build phasing).
"""
import os
import asyncio
import logging

import time

import numpy as np
from fastapi import FastAPI, UploadFile, File, Query, Response, status

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("stt-engine")

MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
ENGINE_NAME = os.environ.get("ENGINE_NAME", "engine")
MAX_CONCURRENCY = int(os.environ.get("MAX_CONCURRENCY", "2"))
# multilingual/whisper are auto-downloaded during setup and must load for
# real; only the arabic engine is allowed to start in stub mode, since no
# public checkpoint exists for it yet (see spec 3.2/3.3).
ALLOW_STUB = os.environ.get("ALLOW_STUB", "true").lower() == "true"
SAMPLE_RATE = 16000

app = FastAPI(title=f"stt-engine-{ENGINE_NAME}")
_semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
_recognizer = None
_model_ready = False
_model_error = None


def _load_model():
    global _recognizer, _model_ready, _model_error
    required = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
    missing = [f for f in required if not os.path.exists(os.path.join(MODEL_DIR, f))]
    if missing:
        msg = (f"{ENGINE_NAME} engine: MODEL_DIR {MODEL_DIR} is missing {missing}.")
        if ALLOW_STUB:
            logger.warning(
                "%s Serving in stub mode until a real model is placed there. "
                "Run scripts/S32_STT-API-models.sh to fetch/verify models.", msg,
            )
            _model_ready = False
            _model_error = None
        else:
            # This engine was supposed to be auto-downloaded during setup --
            # missing files here is a real failure, not an expected stub state.
            logger.error("%s This engine requires ALLOW_STUB=false and should "
                         "have been fetched during setup -- check "
                         "scripts/S32_STT-API-models.sh output.", msg)
            _model_ready = False
            _model_error = msg
        return

    try:
        t0 = time.monotonic()
        import sherpa_onnx
        _recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=os.path.join(MODEL_DIR, "tokens.txt"),
            encoder=os.path.join(MODEL_DIR, "encoder.onnx"),
            decoder=os.path.join(MODEL_DIR, "decoder.onnx"),
            joiner=os.path.join(MODEL_DIR, "joiner.onnx"),
            num_threads=2,
            sample_rate=SAMPLE_RATE,
            feature_dim=80,
            decoding_method="greedy_search",
        )
        _model_ready = True
        _model_error = None
        logger.info("%s engine: model loaded into RAM from %s in %.1fs",
                    ENGINE_NAME, MODEL_DIR, time.monotonic() - t0)
    except Exception as exc:
        _model_ready = False
        _model_error = str(exc)
        logger.error("%s engine: model files present but failed to load: %s",
                     ENGINE_NAME, exc)


@app.on_event("startup")
async def startup():
    # Blocks FastAPI's startup completion until the model is in RAM (or has
    # definitively failed/stubbed) -- no lazy load on first request.
    await asyncio.to_thread(_load_model)


@app.get("/health")
async def health(response: Response):
    if _model_error:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "error", "model_ready": False, "engine": ENGINE_NAME, "error": _model_error}
    if not _model_ready:
        if ALLOW_STUB:
            return {"status": "stub", "model_ready": False, "engine": ENGINE_NAME}
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not_ready", "model_ready": False, "engine": ENGINE_NAME}
    return {"status": "ok", "model_ready": True, "engine": ENGINE_NAME}


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...), lang_hint: str | None = Query(default=None)):
    raw = await audio.read()

    if not _model_ready:
        return {"text": "", "avg_logprob": -10.0, "detected_language": "unknown",
                "warning": f"{ENGINE_NAME} engine has no model loaded"}

    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

    async with _semaphore:
        def _run():
            stream = _recognizer.create_stream()
            stream.accept_waveform(SAMPLE_RATE, samples)
            stream.input_finished()
            while _recognizer.is_ready(stream):
                _recognizer.decode_stream(stream)
            return _recognizer.get_result(stream)

        result = await asyncio.to_thread(_run)

    text = result if isinstance(result, str) else getattr(result, "text", "")
    # sherpa-onnx's greedy decode doesn't expose a calibrated logprob out of
    # the box -- placeholder until the real confidence signal is wired up
    # per spec 3.4 (score + length-normalized log-likelihood + perplexity).
    avg_logprob = -0.2 if text else -5.0

    return {
        "text": text,
        "avg_logprob": avg_logprob,
        # NOT a real detection -- this engine does not yet perform language
        # ID. It is unverified whether the pinned sherpa-onnx version even
        # exposes Nemotron's prompt_index language-conditioning input via
        # the Python API (see https://github.com/k2-fsa/sherpa-onnx/issues/3664).
        # Echoing lang_hint back here would silently misrepresent a request
        # as "detected" when it was just repeated -- report honestly instead.
        "detected_language": "unknown",
    }
EOF

# =============================================================================
# 7. Whisper fallback service
# =============================================================================
write_file "$INSTALL_DIR/whisper-fallback/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
python-multipart==0.0.9
numpy==1.26.4
faster-whisper==1.0.3
# faster-whisper's utils.py imports requests directly for model downloads,
# but does not declare it as a dependency, and the huggingface-hub version
# that resolves alongside it has since moved to httpx and dropped requests
# entirely -- confirmed via a real failed install (ModuleNotFoundError on
# first run), not a hypothetical. Without this pin, nothing installs it.
requests==2.32.3
EOF

write_file "$INSTALL_DIR/whisper-fallback/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

write_file "$INSTALL_DIR/whisper-fallback/app/server.py" <<'EOF'
"""
Permanently-warm faster-whisper fallback. Loaded once at container startup
and never unloaded (no TTL eviction) per spec 3.4 -- fallback traffic is too
sparse to keep it alive via lazy loading, and a cold Whisper load defeats the
purpose of having a fallback at all.

After the model weights are in RAM, one warm-up inference is run against 1s
of silence to force faster-whisper's lazy code paths (tokenizer, feature
extractor, alignment heads) to initialize *now*, rather than during the very
first real fallback request -- which by definition is already racing the
router's circuit-breaker budget.

Weights are pre-downloaded during setup by the installer's "docker compose
run" prefetch step and cached in a persistent volume (models/whisper-cache
-> /root/.cache/huggingface), so this startup load reads from local disk,
not the network -- it should not trigger a download unless the cache volume
was wiped.
"""
import os
import asyncio
import logging

import time

import numpy as np
from fastapi import FastAPI, UploadFile, File, Response, status

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("whisper-fallback")

MODEL_SIZE = os.environ.get("WHISPER_MODEL_SIZE", "small")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "int8")
# 0 = let faster-whisper pick (typically min(4, cpu_count)). Set explicitly
# if the container is under a CPU quota faster-whisper can't see -- left at
# 0, faster-whisper spawns more worker threads than the quota allows and
# they thrash, which is one of the ways a "small" model can end up slower
# than expected.
CPU_THREADS = int(os.environ.get("WHISPER_CPU_THREADS", "0"))
SAMPLE_RATE = 16000

# Any single utterance taking longer than this in warm-up is a red flag that
# the config can't keep up with the router's circuit-breaker budget -- warn
# loudly now, at boot, instead of on the first real (already-racing) request.
WARMUP_WARN_SECONDS = 5.0

app = FastAPI(title="stt-whisper-fallback")
_model = None
_load_error = None


async def _warm_up():
    """Force faster-whisper's lazy code paths to run once at startup."""
    try:
        t0 = time.monotonic()
        silence = np.zeros(SAMPLE_RATE, dtype=np.float32)
        segments, _ = await asyncio.to_thread(
            lambda: _model.transcribe(silence, language=None)
        )
        # transcribe() returns a lazy generator -- list() forces inference.
        list(segments)
        elapsed = time.monotonic() - t0
        logger.info("Whisper warm-up inference completed in %.2fs.", elapsed)
        if elapsed > WARMUP_WARN_SECONDS:
            logger.warning(
                "Whisper warm-up took %.1fs for 1s of audio. At that rate "
                "the fallback will not fit inside the router's "
                "circuit-breaker budget and will time out on real requests. "
                "Consider STT_WHISPER_MODEL_SIZE=base (or tiny), giving "
                "this container more CPU, and/or setting WHISPER_CPU_THREADS "
                "explicitly.", elapsed,
            )
    except Exception as exc:
        logger.warning("Whisper warm-up inference failed (non-fatal): %r", exc)


@app.on_event("startup")
async def startup():
    # Blocks FastAPI's startup completion until weights are in RAM AND the
    # warm-up inference has finished -- this container is meant to be
    # permanently warm, never lazily initialized on the first fallback call
    # (see spec 3.4).
    global _model, _load_error

    def _load():
        from faster_whisper import WhisperModel
        kwargs = dict(device="cpu", compute_type=COMPUTE_TYPE)
        if CPU_THREADS > 0:
            kwargs["cpu_threads"] = CPU_THREADS
        return WhisperModel(MODEL_SIZE, **kwargs)

    t0 = time.monotonic()
    try:
        _model = await asyncio.to_thread(_load)
        logger.info("Whisper %s (%s) loaded into RAM in %.1fs.",
                    MODEL_SIZE, COMPUTE_TYPE, time.monotonic() - t0)
    except Exception as exc:
        _load_error = str(exc)
        logger.error("Whisper failed to load: %s", exc)
        return

    await _warm_up()


@app.get("/health")
async def health(response: Response):
    if _model is None:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "error" if _load_error else "loading",
                "model_ready": False, "error": _load_error}
    return {"status": "ok", "model_ready": True}


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    raw = await audio.read()
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

    def _run():
        segments, info = _model.transcribe(samples, language=None)
        text = " ".join(seg.text.strip() for seg in segments)
        return text, info.language

    t0 = time.monotonic()
    text, detected_language = await asyncio.to_thread(_run)
    elapsed = time.monotonic() - t0
    audio_s = len(samples) / SAMPLE_RATE
    # Real-time factor: <1x means faster than real-time, >1x means slower.
    # Anything above ~1x is a sign the fallback won't fit the router's
    # circuit-breaker budget on realistic utterance lengths.
    logger.info(
        "Transcribed %.2fs of audio in %.2fs (%.2fx real-time).",
        audio_s, elapsed, elapsed / max(audio_s, 1e-6),
    )
    return {"text": text, "avg_logprob": -0.2 if text else -5.0,
            "detected_language": detected_language}
EOF

# =============================================================================
# 8. Model management helper (separate script, backup/restore-style pattern)
# =============================================================================
write_file "$INSTALL_DIR/scripts/S32_STT-API-models.sh" <<EOF
#!/usr/bin/env bash
# Fetches/verifies the public multilingual Nemotron 3.5 sherpa-onnx package.
# The Arabic dialect-tuned model is NOT publicly downloadable (it's your own
# fine-tune per spec 3.2/3.3) -- this script only checks that something has
# been placed in models/arabic and warns clearly if not.
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
MULTI_DIR="\$INSTALL_DIR/models/multilingual"
ARABIC_DIR="\$INSTALL_DIR/models/arabic"
RELEASE_URL="${ENGINE_MODEL_RELEASE_URL}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [[ -f "\$MULTI_DIR/tokens.txt" ]]; then
  echo -e "\${GREEN}[ OK ]\${NC} Multilingual model already present at \$MULTI_DIR"
else
  echo "Downloading multilingual Nemotron 3.5 sherpa-onnx package..."
  tmp=\$(mktemp -d)
  curl -L "\$RELEASE_URL" -o "\$tmp/model.tar.bz2"
  tar -xjf "\$tmp/model.tar.bz2" -C "\$tmp"

  # The release ships files like encoder.int8.onnx / decoder.int8.onnx, not
  # the plain encoder.onnx / decoder.onnx / joiner.onnx / tokens.txt the
  # engine looks for -- copy-and-rename to the canonical names rather than
  # preserving upstream basenames, and don't assume a fixed nesting depth
  # (the release's internal layout isn't something this script has verified
  # as stable across versions).
  #
  # Takes multiple patterns in priority order rather than one wildcard,
  # since "encoder*.onnx" would match both encoder.onnx and
  # encoder.int8.onnx if a future release ships both -- find's match order
  # isn't guaranteed, so relying on "first result wins" could silently pick
  # the wrong precision. Try the exact int8 name first, then fall back to
  # the wildcard only if that's not there.
  copy_first_match() {
    local dest="\$1"; shift
    local pattern src
    for pattern in "\$@"; do
      src=\$(find "\$tmp" -type f -name "\$pattern" | sort | head -n1)
      if [[ -n "\$src" ]]; then
        cp "\$src" "\$dest"
        return 0
      fi
    done
    return 1
  }

  ok=true
  copy_first_match "\$MULTI_DIR/encoder.onnx" "encoder.int8.onnx" "encoder*.onnx" || ok=false
  copy_first_match "\$MULTI_DIR/decoder.onnx" "decoder.int8.onnx" "decoder*.onnx" || ok=false
  copy_first_match "\$MULTI_DIR/joiner.onnx"  "joiner.int8.onnx"  "joiner*.onnx"  || ok=false
  copy_first_match "\$MULTI_DIR/tokens.txt"   "tokens.txt"                        || ok=false
  rm -rf "\$tmp"

  if [[ "\$ok" != true ]]; then
    echo -e "\${RED}[FAIL]\${NC} Extraction didn't produce all 4 expected files."
    echo "        Check the release contents manually: \$RELEASE_URL"
    exit 1
  else
    echo -e "\${GREEN}[ OK ]\${NC} Multilingual model installed at \$MULTI_DIR"
  fi
fi

if [[ -f "\$ARABIC_DIR/tokens.txt" ]]; then
  echo -e "\${GREEN}[ OK ]\${NC} Arabic dialect-tuned model present at \$ARABIC_DIR"
else
  echo -e "\${YELLOW}[WARN]\${NC} No Arabic model at \$ARABIC_DIR."
  echo "        The Arabic engine will serve in stub mode (empty transcripts)"
  echo "        until you export your fine-tuned checkpoint to encoder.onnx /"
  echo "        decoder.onnx / joiner.onnx / tokens.txt and place them there."
  echo "        See stt-api-spec.md section 3.2/3.3 for the training plan."
fi
EOF
chmod +x "$INSTALL_DIR/scripts/S32_STT-API-models.sh"

# =============================================================================
# 9. Audit-log retention cleanup helper
# =============================================================================
write_file "$INSTALL_DIR/scripts/cleanup_audit_logs.sh" <<EOF
#!/usr/bin/env bash
# Deletes audit log files older than AUDIT_RETENTION_DAYS. Add to host cron,
# e.g.: 0 3 * * * $INSTALL_DIR/scripts/cleanup_audit_logs.sh
set -euo pipefail
AUDIT_DIR="$INSTALL_DIR/logs/audit"
RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-30}"
find "\$AUDIT_DIR" -name "*.jsonl" -mtime "+\$RETENTION_DAYS" -delete
EOF
chmod +x "$INSTALL_DIR/scripts/cleanup_audit_logs.sh"

# =============================================================================
# 10. Fetch models, build, start
# =============================================================================
log_info "Fetching/verifying models..."
bash "$INSTALL_DIR/scripts/S32_STT-API-models.sh"

log_info "Building images (this can take a few minutes on first run)..."
(cd "$INSTALL_DIR" && docker compose build)

log_info "Pre-downloading Whisper fallback weights (one-time, cached under models/whisper-cache)..."
(cd "$INSTALL_DIR" && docker compose run --rm stt-whisper-fallback python -c \
  "from faster_whisper import WhisperModel; WhisperModel('${WHISPER_MODEL_SIZE}', device='cpu', compute_type='${WHISPER_COMPUTE_TYPE}'); print('Whisper weights cached.')")

log_info "Starting stack..."
(cd "$INSTALL_DIR" && docker compose up -d)

# =============================================================================
# 11. Health check polling
# =============================================================================
log_info "Waiting for services to report healthy..."
ATTEMPTS=30
for i in $(seq 1 "$ATTEMPTS"); do
  if curl -sf "http://localhost:${ROUTER_PORT}/health" >/dev/null 2>&1; then
    log_success "Router is healthy."
    break
  fi
  if [[ "$i" == "$ATTEMPTS" ]]; then
    log_error "Router did not become healthy in time. Check: docker compose -f $INSTALL_DIR/docker-compose.yml logs"
    exit 1
  fi
  sleep 5
done

# =============================================================================
# 11b. Verify each model actually loaded into RAM (not just that the process
#      is alive) -- this is the check that matters for "did setup work".
# =============================================================================
check_model_ready() {
  local name="$1" container="$2" required="$3"
  local body
  body=$(docker exec "$container" curl -sf "http://localhost:8000/health" 2>/dev/null || echo '{}')
  if echo "$body" | grep -Eq '"model_ready":[[:space:]]*true'; then
    log_success "$name: model loaded into RAM."
    return 0
  fi
  if [[ "$required" == true ]]; then
    log_error "$name: model did NOT load into RAM. Response: $body"
    return 1
  else
    log_warn "$name: model not loaded yet (expected until its checkpoint is supplied). Response: $body"
    return 0
  fi
}

VERIFY_FAILED=false
check_model_ready "Multilingual engine" "stt-multilingual-engine" true || VERIFY_FAILED=true
check_model_ready "Whisper fallback"    "stt-whisper-fallback"    true || VERIFY_FAILED=true
check_model_ready "Arabic engine"       "stt-arabic-engine"       false

if [[ "$VERIFY_FAILED" == true ]]; then
  log_error "One or more required models failed to load into RAM. Check:"
  log_error "  docker compose -f $INSTALL_DIR/docker-compose.yml logs stt-multilingual-engine stt-whisper-fallback"
  exit 1
fi

# =============================================================================
# 12. Summary
# =============================================================================
echo ""
log_success "STT API stack is up."
echo "  Local (debug only):   http://127.0.0.1:${ROUTER_PORT}/v1/transcribe"
echo "  Arabic engine:        internal only, reachable as stt-arabic-engine:8000 on ${INTERNAL_NETWORK_NAME}"
echo "  Multilingual engine:  internal only, reachable as stt-multilingual-engine:8000 on ${INTERNAL_NETWORK_NAME}"
echo "  Whisper fallback:     internal only, reachable as stt-whisper-fallback:8000 on ${INTERNAL_NETWORK_NAME}"
echo ""
log_info "Nginx Proxy Manager Configuration"
echo "  Domain:               ${DOMAIN}"
echo "  Forward Hostname/IP:  stt-router"
echo "  Forward Port:         8000"
echo "  Scheme:                http"
echo "  Enable:               Block Common Exploits, Websockets Support, Force SSL, HTTP/2, HSTS"
echo ""
log_info "Verifying Whisper fallback warm-up latency..."
docker logs --tail 50 stt-whisper-fallback 2>&1 \
  | grep -E "warm-up inference|real-time" \
  | tail -3 \
  || log_info "  (no warm-up log line yet -- check 'docker logs stt-whisper-fallback')"
echo ""
log_warn "If you upgraded from S31 without --force, .env was not regenerated and"
log_warn "docker-compose.yml still has the old baked-in WHISPER_MODEL_SIZE. To pick"
log_warn "up the v2 defaults: re-run with --force, or edit docker-compose.yml and set"
log_warn "WHISPER_MODEL_SIZE=small, then 'docker compose up -d --force-recreate'."
echo ""
log_warn "Before this is production-ready, per stt-api-spec.md:"
echo "   1. Train the dialect gate classifier and place it at models/dialect_gate.onnx"
echo "   2. Export your Arabic dialect fine-tune into models/arabic/ (encoder/decoder/joiner/tokens)"
echo "   3. Calibrate DIALECT_GULF_THRESHOLD, DIALECT_OTHER_THRESHOLD, CONFIDENCE_THRESHOLD"
echo "      against the 1,000-utterance calibration set -- current values in .env are placeholders"
echo "   4. Get legal sign-off on audit logging, then set AUDIT_ENABLED=true in .env"
echo "   5. Add scripts/cleanup_audit_logs.sh to host cron once logging is enabled"
echo "   6. Once the engine's detected_language field is real, set LID_ENABLED=true in .env"