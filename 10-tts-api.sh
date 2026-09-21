#!/usr/bin/env bash
# ==============================================================================
# TTS API v4.0.2 — Installer (Final Working CPU Version)
# ==============================================================================

set -euo pipefail
IFS=$'
	'

SCRIPT_VERSION="4.0.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/tts-api-v4"
LOG_FILE="/tmp/tts-api-v4-setup.log"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[ERR]${NC} $1" | tee -a "$LOG_FILE"; }
fatal() { echo -e "${RED}[FATAL]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

exec > >(tee -a "$LOG_FILE") 2>&1

echo "TTS API v${SCRIPT_VERSION} setup started at ${TIMESTAMP}"

# ------------------------------------------------------------------------------
# STEP 01 — Pre-flight checks
# ------------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || fatal "Run as root: sudo bash $0"
command -v docker >/dev/null || fatal "Docker not installed."
command -v openssl >/dev/null || fatal "openssl not installed."
docker info >/dev/null 2>&1 || fatal "Docker daemon not running."
docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 required."
docker network inspect proxy-network >/dev/null 2>&1 || docker network create proxy-network

ok "Pre-flight checks passed"

# ------------------------------------------------------------------------------
# STEP 02 — FIXED RESOURCE CONTRACT
# ------------------------------------------------------------------------------

TOTAL_VCPUS_DETECTED="$(nproc --all 2>/dev/null || echo 9)"
TOTAL_RAM_KB_DETECTED="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
TOTAL_RAM_GB_DETECTED="$(awk -v kb="$TOTAL_RAM_KB_DETECTED" 'BEGIN{printf "%.1f", kb/1048576}')"

info "Detected host: ${TOTAL_VCPUS_DETECTED} vCPUs, ${TOTAL_RAM_GB_DETECTED} GB RAM"

[[ "$TOTAL_VCPUS_DETECTED" -lt 9 ]] && warn "Host has fewer than 9 vCPUs; fixed contract assumes 9 vCPU / 15 GB. Adjust AR_CPUS/EN_CPUS below if needed."

# --- FIXED ALLOCATION (design target: 9 vCPU / 15 GB) ---
AR_CPUS="6.0"
AR_MEM_LIMIT="9g"
AR_THREADS="6"
AR_CONCURRENT="1"
AR_WORKERS="1"
AR_EXECUTOR_WORKERS="1"

EN_CPUS="2.0"
EN_MEM_LIMIT="2g"
EN_THREADS="2"
EN_CONCURRENT="4"
EN_WORKERS="1"

ROUTER_CPUS="0.5"
ROUTER_MEM_LIMIT="512m"

REDIS_CPUS="0.5"
REDIS_MEM_LIMIT="512m"

ok "Fixed resource contract set: AR ${AR_CPUS} vCPU/${AR_MEM_LIMIT}, EN ${EN_CPUS} vCPU/${EN_MEM_LIMIT}"

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/.env.resources" <<ENVEOF
# ============================================================
# v4 FIXED RESOURCE CONTRACT — generated once at install time.
# Python services read these. They must NEVER re-detect CPU/RAM
# or override these values at runtime.
# ============================================================

AR_CPUS=${AR_CPUS}
AR_MEM_LIMIT=${AR_MEM_LIMIT}
AR_THREADS=${AR_THREADS}
AR_CONCURRENT=${AR_CONCURRENT}
AR_WORKERS=${AR_WORKERS}
AR_EXECUTOR_WORKERS=${AR_EXECUTOR_WORKERS}

OMP_NUM_THREADS=${AR_THREADS}
MKL_NUM_THREADS=${AR_THREADS}
OPENBLAS_NUM_THREADS=${AR_THREADS}
NUMEXPR_NUM_THREADS=${AR_THREADS}

EN_CPUS=${EN_CPUS}
EN_MEM_LIMIT=${EN_MEM_LIMIT}
EN_THREADS=${EN_THREADS}
EN_CONCURRENT=${EN_CONCURRENT}
EN_WORKERS=${EN_WORKERS}

ROUTER_CPUS=${ROUTER_CPUS}
ROUTER_MEM_LIMIT=${ROUTER_MEM_LIMIT}

REDIS_CPUS=${REDIS_CPUS}
REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT}
ENVEOF

ok "Wrote fixed resource contract to $INSTALL_DIR/.env.resources"

APP_SECRET_KEY="$(openssl rand -hex 24)"
ADMIN_API_KEY="$(openssl rand -hex 24)"
REDIS_PASSWORD="$(openssl rand -hex 16)"

cat > "$INSTALL_DIR/.env" <<ENVEOF
API_SECRET_KEY=${APP_SECRET_KEY}
ADMIN_API_KEY=${ADMIN_API_KEY}
REDIS_PASSWORD=${REDIS_PASSWORD}
CACHE_NAMESPACE_VERSION=v4
PLANNER_VERSION=1
NORMALIZER_VERSION=1
ASSEMBLER_VERSION=1
ENVEOF

ok "Wrote credentials and cache-version markers to $INSTALL_DIR/.env"

mkdir -p "$INSTALL_DIR"/{app/router,app/arabic,app/multilingual,app/shared,voices/arabic,logs,scripts,data/prometheus}

# ------------------------------------------------------------------------------
# STEP 02B — Arabic voice assets
# ------------------------------------------------------------------------------

V4_EMBEDDING_PATH="$INSTALL_DIR/voices/arabic/master_embedding.pt"
V4_REFERENCE_CLIPS_DIR="$INSTALL_DIR/voices/arabic/reference_clips"

V3_EMBEDDING_CANDIDATES=(
"/opt/tts-api/voices/arabic/master_embedding.pt"
"/opt/tts-api/voices/arabic/masterembedding.pt"
"/opt/tts-api/app/voices/arabic/master_embedding.pt"
"/opt/tts-api/app/voices/arabic/masterembedding.pt"
)

V3_CLIPS_CANDIDATES=(
"/opt/tts-api/voices/arabic/reference_clips"
"/opt/tts-api/voices/arabic/referenceclips"
)

mkdir -p "$V4_REFERENCE_CLIPS_DIR"

if [[ -f "$V4_EMBEDDING_PATH" ]]; then
    ok "Arabic master embedding already present: $V4_EMBEDDING_PATH"
else
    EMBEDDING_SOURCE=""
    for candidate in "${V3_EMBEDDING_CANDIDATES[@]}"; do
        if [[ -f "$candidate" ]]; then
            EMBEDDING_SOURCE="$candidate"
            break
        fi
    done

    if [[ -n "$EMBEDDING_SOURCE" ]]; then
        cp -f "$EMBEDDING_SOURCE" "$V4_EMBEDDING_PATH"
        ok "Copied Arabic master embedding from v3: $EMBEDDING_SOURCE"
    else
        for clips_source in "${V3_CLIPS_CANDIDATES[@]}"; do
            if compgen -G "$clips_source/*.wav" >/dev/null; then
                cp -an "$clips_source"/*.wav "$V4_REFERENCE_CLIPS_DIR/" || true
                ok "Copied existing v3 Arabic reference clips; v4 will build embedding at first startup"
                break
            fi
        done

        if ! compgen -G "$V4_REFERENCE_CLIPS_DIR/*.wav" >/dev/null; then
            info "No reusable Arabic assets found. v4 Arabic container will download corpus, select clips, and build embedding on first startup."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# STEP 03 — Shared language registry
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/supported_languages.yaml" <<'YAMLEOF'
# ============================================================
# v4 Supported Language Registry
# Built from n8n workflow audit — NOT the old v3 hard-coded list.
# Update this file only after auditing real production traffic.
# ============================================================

languages:
  ar:
    engine: xtts_arabic
    aliases: [ar-sa, ar-eg, ar-ae, ar-kw, ara, arabic]
    script: Arabic
    splitter: arabic
    normalizer: arabic

  en:
    engine: kokoro
    aliases: [en-us, en-gb, english]
    script: Latin
    splitter: latin
    normalizer: latin

  fr:
    engine: kokoro
    aliases: [fr-fr, french]
    script: Latin
    splitter: latin
    normalizer: latin

  de:
    engine: kokoro
    aliases: [german]
    script: Latin
    splitter: latin
    normalizer: latin

  es:
    engine: kokoro
    aliases: [spanish]
    script: Latin
    splitter: latin
    normalizer: latin

  pt:
    engine: kokoro
    aliases: [pt-br, portuguese]
    script: Latin
    splitter: latin
    normalizer: latin

  ja:
    engine: kokoro
    aliases: [japanese]
    script: CJK
    splitter: cjk
    normalizer: cjk

  ko:
    engine: kokoro
    aliases: [korean]
    script: CJK
    splitter: cjk
    normalizer: cjk

  zh:
    engine: kokoro
    aliases: [chinese, zh-cn]
    script: CJK
    splitter: cjk
    normalizer: cjk

# Anything not listed here (including "auto", blank, or unknown codes)
# MUST return HTTP 422 from the router. Never silently route to Kokoro.
YAMLEOF

ok "Wrote language registry (edit after workflow audit before go-live)"

cat > "$INSTALL_DIR/scripts/audit_tts_languages.py" <<'PYEOF'
#!/usr/bin/env python3
"""Extract every distinct `language` value sent to /v1/text-to-speech
from an exported n8n workflows.json. Run BEFORE trusting supported_languages.yaml."""

import json
import re
from collections import defaultdict
from pathlib import Path

INPUT = Path("workflows.json")
OUTPUT = Path("tts-language-audit.csv")

TTS_PATH = re.compile(r"/v1/text-to-speech\b", re.IGNORECASE)
LANGUAGE_KEY = re.compile(r'["\']?language["\']?\s*[:=]\s*["\']([^"\']+)["\']', re.IGNORECASE)


def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def find_language_values(node):
    found = []
    params = node.get("parameters", {})

    for obj in walk(params):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if str(key).lower() == "language":
                    found.append(value)

    blob = json.dumps(params, ensure_ascii=False)
    for match in LANGUAGE_KEY.finditer(blob):
        found.append(match.group(1))

    if not found:
        found.append("(not found / possibly upstream expression)")

    return sorted({v.strip() if isinstance(v, str) else json.dumps(v) for v in found})


def main():
    data = json.loads(INPUT.read_text(encoding="utf-8"))
    workflows = data.get("data", data) if isinstance(data, dict) else data

    if isinstance(workflows, dict):
        workflows = workflows.get("workflows", [])

    rows = []

    for wf in workflows:
        wf_name = wf.get("name", "(unnamed)")
        wf_active = wf.get("active", False)

        for node in wf.get("nodes", []):
            blob = json.dumps(node, ensure_ascii=False)
            if not TTS_PATH.search(blob):
                continue

            for raw in find_language_values(node):
                normalized = raw.lower().strip() if not str(raw).startswith("=") else "(expression)"
                rows.append({
                    "workflow": wf_name,
                    "active": str(wf_active).lower(),
                    "node": node.get("name", "(unnamed)"),
                    "raw_language": raw,
                    "normalized_language": normalized,
                    "node_type": node.get("type", ""),
                })

    rows.sort(key=lambda r: (r["normalized_language"], r["workflow"], r["node"]))

    headers = ["workflow", "active", "node", "raw_language", "normalized_language", "node_type"]

    with OUTPUT.open("w", encoding="utf-8") as f:
        f.write(",".join(headers) + "\n")
        for row in rows:
            f.write(",".join('"' + str(row[h]).replace('"', '""') + '"' for h in headers) + "\n")

    unique = defaultdict(list)
    for row in rows:
        unique[row["normalized_language"]].append(row)

    print(f"Wrote: {OUTPUT}")
    print("\nDistinct language values found in n8n workflows:")

    for lang, occ in sorted(unique.items()):
        active = sum(o["active"] == "true" for o in occ)
        print(f"  {lang}: {len(occ)} node(s), {active} active")


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$INSTALL_DIR/scripts/audit_tts_languages.py"

ok "Wrote n8n language audit script (run this against workflows.json before go-live)"

# ------------------------------------------------------------------------------
# STEP 03B — Standalone Arabic corpus provisioner
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/scripts/provision_arabic_reference_clips.py" <<'PYEOF'
#!/usr/bin/env python3
"""Download Arabic Speech Corpus and select reference clips for XTTS.
Equivalent to v3 Step 05; safe to rerun. Default target is v4 voice volume."""

import argparse
import json
import math
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

import numpy as np
import torchaudio

CORPUS_URL = "https://en.arabicspeechcorpus.com/arabic-speech-corpus.zip"


def load_audio(path):
    try:
        waveform, sr = torchaudio.load(path)

        if waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)

        data = waveform.numpy().flatten().astype("float32")
        return data, sr

    except Exception as e:
        raise RuntimeError(f"Failed to load {path}: {e}")


def score_clip(path):
    data, sr = load_audio(path)

    if data is None or len(data) == 0:
        return None

    dur = len(data) / sr
    if not 3 <= dur <= 10:
        return None

    rms = float(np.sqrt(np.mean(data ** 2)))
    if rms < 0.02 or float(np.max(np.abs(data))) > 0.95:
        return None

    frame = max(1, len(data) // 20)
    powers = sorted(float(np.mean(data[i:i + frame] ** 2)) for i in range(0, len(data) - frame, frame))
    noise = max(float(np.mean(powers[:max(1, len(powers) // 10)])), 1e-10)
    snr = 10 * math.log10(max(float(np.mean(data ** 2)), 1e-10) / noise)

    if snr < 20:
        return None

    return {
        "path": path,
        "duration": dur,
        "rms": rms,
        "snr": snr,
        "score": rms * (snr / 40) * (1 - abs(dur - 6.5) / 6.5),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="/app/voices/arabic/reference_clips")
    ap.add_argument("--stats", default="/app/voices/arabic/corpus_stats.json")
    ap.add_argument("--url", default=CORPUS_URL)
    ap.add_argument("--count", type=int, default=50)

    args = ap.parse_args()

    target, stats = Path(args.target), Path(args.stats)
    target.mkdir(parents=True, exist_ok=True)

    existing = list(target.glob("*.wav")) + list(target.glob("*.WAV"))
    if existing:
        print(f"Reference clips already present: {len(existing)}; skipping corpus download")
        return

    with tempfile.TemporaryDirectory(prefix="arabic-corpus-") as temp:
        temp = Path(temp)
        archive = temp / "corpus.zip"
        extracted = temp / "corpus"

        print(f"Downloading Arabic Speech Corpus from {args.url}")
        subprocess.run(["wget", "--show-progress", "-O", str(archive), args.url], check=True)

        with zipfile.ZipFile(archive) as z:
            z.extractall(extracted)

        wavs = list(extracted.rglob("*.wav")) + list(extracted.rglob("*.WAV"))
        print(f"Found {len(wavs)} WAV files; scoring quality")

        scored = []

        for path in wavs:
            try:
                result = score_clip(path)
                if result:
                    scored.append(result)
            except Exception as e:
                print(f"Skip {path.name}: {e}")

        if len(scored) < 5:
            raise RuntimeError(f"Only {len(scored)} clips passed quality selection; cannot build robust embedding")

        scored.sort(key=lambda x: x["score"], reverse=True)
        selected = scored[:args.count]

        for i, item in enumerate(selected):
            shutil.copy2(item["path"], target / f"clip_{i:03d}.wav")

        stats.parent.mkdir(parents=True, exist_ok=True)
        stats.write_text(json.dumps({
            "total_wavs": len(wavs),
            "passed_quality": len(scored),
            "selected": len(selected),
            "clips_dir": str(target),
        }, indent=2))

        print(f"Selected {len(selected)} clips -> {target}")


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$INSTALL_DIR/scripts/provision_arabic_reference_clips.py"

ok "Wrote standalone Arabic corpus provisioner (using torchaudio)"

# ------------------------------------------------------------------------------
# STEP 04 — Shared models
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/models.py" <<'PYEOF'
from typing import Optional, Literal, List

from pydantic import BaseModel, Field, field_validator


class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=20000)
    language: str = Field(default="en", description="BCP-47 code, e.g. ar, en, fr")
    voice_id: Optional[str] = None
    output_format: Literal["mp3", "wav", "ogg"] = "mp3"
    speed: float = Field(default=1.0, ge=0.5, le=2.0)
    pitch: float = Field(default=1.0, ge=0.5, le=2.0)
    normalize: bool = True

    @field_validator("text")
    @classmethod
    def clean_text(cls, v):
        return v.strip()

    @field_validator("language")
    @classmethod
    def normalize_language(cls, v):
        return v.lower().strip()


class PlannedChunk(BaseModel):
    index: int
    text: str
    language: str
    engine: str
    boundary: Literal["paragraph", "sentence", "question", "semicolon", "comma", "word_boundary"]
    punctuation: str
    pause_ms: int


class SynthesizeRequest(BaseModel):
    """Internal request from router to an engine. Carries a pre-built plan,
    NOT raw text — the router already split, normalized, and validated it."""

    request_id: str
    chunks: List[PlannedChunk]
    voice_id: Optional[str] = None
    output_format: str = "mp3"
    speed: float = 1.0
    pitch: float = 1.0
    normalize: bool = True


class HealthResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    status: str
    engine: str
    model_loaded: bool
    active_syntheses: int
    queue_depth: int
    resources: Optional[dict] = None
    resource_contract_valid: Optional[bool] = None
    version: str = "4.0.2"
PYEOF

ok "Wrote shared/models.py"

# ------------------------------------------------------------------------------
# STEP 05 — Shared language registry loader
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/languages.py" <<'PYEOF'
"""Single source of truth for supported languages. Router and engines both
import from here — no engine may invent its own fallback language logic."""

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

import yaml

logger = logging.getLogger(__name__)

REGISTRY_PATH = Path(__file__).parent / "supported_languages.yaml"


@dataclass(frozen=True)
class LanguageSpec:
    code: str
    engine: str
    script: str
    splitter: str
    normalizer: str
    aliases: tuple


class LanguageRegistry:
    def __init__(self, path: Path = REGISTRY_PATH):
        self._by_code: Dict[str, LanguageSpec] = {}
        self._alias_to_code: Dict[str, str] = {}
        self._load(path)

    def _load(self, path: Path) -> None:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)

        for code, spec in data.get("languages", {}).items():
            aliases = tuple(a.lower() for a in spec.get("aliases", []))

            self._by_code[code] = LanguageSpec(
                code=code,
                engine=spec["engine"],
                script=spec.get("script", ""),
                splitter=spec.get("splitter", "latin"),
                normalizer=spec.get("normalizer", "latin"),
                aliases=aliases,
            )

            self._alias_to_code[code] = code
            for alias in aliases:
                self._alias_to_code[alias] = code

        logger.info("Loaded %d supported languages from %s", len(self._by_code), path)

    def resolve(self, requested: str) -> Optional[LanguageSpec]:
        """Returns None if unsupported. Caller MUST reject the request —
        never silently default to English rules."""

        if not requested:
            return None

        key = requested.lower().strip()
        code = self._alias_to_code.get(key)

        if code is None:
            return None

        return self._by_code[code]

    def supported_codes(self):
        return sorted(self._by_code.keys())


registry = LanguageRegistry()
PYEOF

ok "Wrote shared/languages.py"

# ------------------------------------------------------------------------------
# STEP 06 — Shared normalizer
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/normalizer.py" <<'PYEOF'
"""Per-language text normalization. Runs ONCE per planned chunk, before
synthesis. Never applied twice (n8n must not pre-normalize)."""

import re
import unicodedata

_WHITESPACE_RE = re.compile(r"\s+")
_REPEATED_PUNCT_RE = re.compile(r"([!?.,؛،:])\1{1,}")

_ARABIC_INDIC_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789")
_EXTENDED_ARABIC_INDIC_DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹", "0123456789")


def normalize_common(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = _WHITESPACE_RE.sub(" ", text.replace("\n", "\n")).strip()
    text = _REPEATED_PUNCT_RE.sub(r"\1", text)
    return text


def normalize_arabic(text: str) -> str:
    text = normalize_common(text)
    text = unicodedata.normalize("NFKC", text)
    text = text.translate(_ARABIC_INDIC_DIGITS)
    text = text.translate(_EXTENDED_ARABIC_INDIC_DIGITS)

    # Presentation-form / tatweel cleanup — safe, does not change pronunciation.
    text = text.replace("\u0640", "")  # tatweel

    return text


def normalize_latin(text: str) -> str:
    text = normalize_common(text)
    text = unicodedata.normalize("NFKC", text)
    return text


def normalize_cjk(text: str) -> str:
    text = normalize_common(text)
    text = unicodedata.normalize("NFKC", text)
    return text


NORMALIZERS = {
    "arabic": normalize_arabic,
    "latin": normalize_latin,
    "cjk": normalize_cjk,
}


def normalize(text: str, normalizer_name: str) -> str:
    fn = NORMALIZERS.get(normalizer_name, normalize_latin)
    return fn(text)
PYEOF

ok "Wrote shared/normalizer.py"

# ------------------------------------------------------------------------------
# STEP 07 — Shared text planner
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/text_planner.py" <<'PYEOF'
"""Language-aware sentence/phrase splitting. Replaces every v3 split_text().
No fixed character slicing. No mid-word breaks. Returns chunks WITH metadata
(language, boundary type, punctuation, pause) — never bare strings."""

import re
from typing import List

from languages import registry
from models import PlannedChunk
from normalizer import normalize

ARABIC_SENTENCE_END = "؟！."
ARABIC_SEMI = "؛:"
ARABIC_COMMA = "،"

LATIN_SENTENCE_END = ".!?"
LATIN_SEMI = ";:"
LATIN_COMMA = ","

PAUSE_MS = {
    "paragraph": 350,
    "sentence": 240,
    "question": 240,
    "semicolon": 180,
    "comma": 100,
    "word_boundary": 80,
}

AR_TARGET_CHARS = 190
AR_MIN_CHARS = 160
AR_MAX_CHARS = 220


def _split_paragraphs(text: str) -> List[str]:
    return [p.strip() for p in text.split("\n") if p.strip()]


def _split_arabic_sentences(paragraph: str) -> List[tuple]:
    """Returns list of (sentence_text, boundary_type, punctuation)."""

    pattern = re.compile(
        rf"([^{re.escape(ARABIC_SENTENCE_END + ARABIC_SEMI)}]+[{re.escape(ARABIC_SENTENCE_END + ARABIC_SEMI)}]?)"
    )

    pieces = [p.strip() for p in pattern.findall(paragraph) if p.strip()]

    if not pieces:
        pieces = [paragraph]

    results = []

    for piece in pieces:
        last_char = piece[-1] if piece else ""

        if last_char in "؟！":
            boundary = "question" if last_char == "؟" else "sentence"
        elif last_char == ".":
            boundary = "sentence"
        elif last_char in ARABIC_SEMI:
            boundary = "semicolon"
        else:
            boundary = "sentence"

        results.append((piece, boundary, last_char))

    return results


def _hard_split_long_arabic(sentence: str) -> List[tuple]:
    """Split an oversized Arabic sentence on commas first, then on safe
    whitespace word boundaries. NEVER slices inside a word."""

    if len(sentence) <= AR_MAX_CHARS:
        return [(sentence, "sentence", sentence[-1] if sentence else "")]

    comma_parts = [p.strip() for p in sentence.split(ARABIC_COMMA) if p.strip()]

    if len(comma_parts) > 1:
        results = []

        for i, part in enumerate(comma_parts):
            is_last = i == len(comma_parts) - 1
            punctuation = "" if is_last else ARABIC_COMMA
            boundary = "sentence" if is_last else "comma"

            results.extend(
                _hard_split_long_arabic(part)
                if len(part) > AR_MAX_CHARS
                else [(part, boundary, punctuation)]
            )

        return results

    # No commas available — split on whitespace word boundaries only.
    words = sentence.split(" ")
    results = []
    current = ""

    for word in words:
        candidate = (current + " " + word).strip() if current else word

        if len(candidate) > AR_MAX_CHARS and current:
            results.append((current, "word_boundary", ""))
            current = word
        else:
            current = candidate

    if current:
        results.append((current, "sentence", ""))

    return results


def plan_arabic(text: str) -> List[PlannedChunk]:
    text = normalize(text, "arabic")

    chunks: List[PlannedChunk] = []
    index = 0

    paragraphs = _split_paragraphs(text)

    for p_idx, paragraph in enumerate(paragraphs):
        sentences = _split_arabic_sentences(paragraph)

        buffer = ""
        buffer_boundary = ""
        buffer_punctuation = ""

        def flush(boundary: str, punctuation: str):
            nonlocal buffer, buffer_boundary, buffer_punctuation, index

            if not buffer.strip():
                return

            chunks.append(PlannedChunk(
                index=index,
                text=buffer.strip(),
                language="ar",
                engine="xtts_arabic",
                boundary=boundary,
                punctuation=punctuation,
                pause_ms=PAUSE_MS.get(boundary, 200),
            ))

            index += 1

            buffer = ""
            buffer_boundary = ""
            buffer_punctuation = ""

        for sentence, boundary, punctuation in sentences:
            if len(sentence) > AR_MAX_CHARS:
                flush(buffer_boundary or "sentence", buffer_punctuation)

                for sub_text, sub_boundary, sub_punct in _hard_split_long_arabic(sentence):
                    chunks.append(PlannedChunk(
                        index=index,
                        text=sub_text.strip(),
                        language="ar",
                        engine="xtts_arabic",
                        boundary=sub_boundary,
                        punctuation=sub_punct,
                        pause_ms=PAUSE_MS.get(sub_boundary, 150),
                    ))
                    index += 1

                continue

            candidate = (buffer + " " + sentence).strip() if buffer else sentence

            if len(candidate) >= AR_TARGET_CHARS or len(candidate) > AR_MAX_CHARS:
                flush(boundary, punctuation)
                buffer = sentence
                buffer_boundary = boundary
                buffer_punctuation = punctuation
            else:
                buffer = candidate
                buffer_boundary = boundary
                buffer_punctuation = punctuation

        flush(buffer_boundary or "sentence", buffer_punctuation)

        if chunks and p_idx < len(paragraphs) - 1:
            chunks[-1] = chunks[-1].model_copy(update={
                "boundary": "paragraph",
                "pause_ms": PAUSE_MS["paragraph"],
            })

    if chunks:
        chunks[-1] = chunks[-1].model_copy(update={"pause_ms": 0})

    return chunks


def plan_latin(text: str, language: str, engine: str) -> List[PlannedChunk]:
    text = normalize(text, "latin")

    sentences = re.split(r"(?<=[.!?])\s+", text.strip())

    chunks: List[PlannedChunk] = []

    for i, sentence in enumerate(s for s in sentences if s.strip()):
        last_char = sentence.strip()[-1] if sentence.strip() else ""
        boundary = "question" if last_char == "?" else "sentence"

        chunks.append(PlannedChunk(
            index=i,
            text=sentence.strip(),
            language=language,
            engine=engine,
            boundary=boundary,
            punctuation=last_char,
            pause_ms=PAUSE_MS.get(boundary, 200),
        ))

    if chunks:
        chunks[-1] = chunks[-1].model_copy(update={"pause_ms": 0})

    return chunks


def plan_cjk(text: str, language: str, engine: str) -> List[PlannedChunk]:
    text = normalize(text, "cjk")

    sentences = re.split(r"(?<=[。！？.!?])", text.strip())

    chunks: List[PlannedChunk] = []

    for i, sentence in enumerate(s for s in sentences if s.strip()):
        chunks.append(PlannedChunk(
            index=i,
            text=sentence.strip(),
            language=language,
            engine=engine,
            boundary="sentence",
            punctuation=sentence.strip()[-1],
            pause_ms=PAUSE_MS["sentence"],
        ))

    if chunks:
        chunks[-1] = chunks[-1].model_copy(update={"pause_ms": 0})

    return chunks


def build_plan(text: str, requested_language: str) -> List[PlannedChunk]:
    """Single entry point used by the router. Raises ValueError for
    unsupported languages — caller must convert this to HTTP 422."""

    spec = registry.resolve(requested_language)

    if spec is None:
        raise ValueError(f"unsupported_language:{requested_language}")

    if spec.splitter == "arabic":
        return plan_arabic(text)
    elif spec.splitter == "cjk":
        return plan_cjk(text, spec.code, spec.engine)
    else:
        return plan_latin(text, spec.code, spec.engine)
PYEOF

ok "Wrote shared/text_planner.py"

# ------------------------------------------------------------------------------
# STEP 08 — Shared audio assembler
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/audio_assembler.py" <<'PYEOF'
"""Assembles PCM chunks into ONE final audio file with punctuation-aware
pauses, single normalization pass, single encode. Replaces the v3 pattern:

    raw_audio = np.concatenate(audio_chunks)

which produced abrupt joins and no inter-sentence silence."""

import io
import logging
import subprocess
from dataclasses import dataclass
from typing import List, Tuple

import numpy as np

logger = logging.getLogger(__name__)


@dataclass
class ChunkResult:
    pcm: np.ndarray
    sample_rate: int
    pause_ms: int


class AudioAssembler:
    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self._segments: List[np.ndarray] = []

    def append(self, chunk: ChunkResult) -> None:
        pcm = chunk.pcm

        if pcm.dtype != np.float32:
            pcm = pcm.astype(np.float32)

        if pcm.ndim > 1:
            pcm = pcm.mean(axis=1)

        if not np.all(np.isfinite(pcm)):
            raise ValueError("Non-finite samples in synthesized chunk audio")

        if chunk.sample_rate != self.sample_rate:
            raise ValueError(
                f"Sample rate mismatch: expected {self.sample_rate}, got {chunk.sample_rate}"
            )

        self._segments.append(pcm)

        if chunk.pause_ms > 0:
            silence_samples = int(self.sample_rate * chunk.pause_ms / 1000)
            self._segments.append(np.zeros(silence_samples, dtype=np.float32))

    def finalize_pcm(self) -> np.ndarray:
        if not self._segments:
            raise ValueError("No audio segments to assemble")

        return np.concatenate(self._segments)

    @staticmethod
    def normalize_peak(pcm: np.ndarray, target_peak: float = 0.95) -> np.ndarray:
        peak = float(np.max(np.abs(pcm))) if pcm.size else 0.0

        if peak <= 0:
            return pcm

        gain = target_peak / peak
        return np.clip(pcm * gain, -1.0, 1.0)

    def finalize(self, normalize: bool = True) -> Tuple[np.ndarray, int]:
        pcm = self.finalize_pcm()

        if normalize:
            pcm = self.normalize_peak(pcm)

        return pcm, self.sample_rate


def encode_pcm_to_bytes(pcm: np.ndarray, sample_rate: int, output_format: str) -> bytes:
    """Encodes float32 PCM to the requested format via ffmpeg, exactly once."""

    pcm_int16 = np.clip(pcm * 32767.0, -32768, 32767).astype(np.int16)
    raw_bytes = pcm_int16.tobytes()

    codec_map = {"mp3": "libmp3lame", "wav": "pcm_s16le", "ogg": "libvorbis"}
    codec = codec_map.get(output_format, "libmp3lame")

    fmt_map = {"mp3": "mp3", "wav": "wav", "ogg": "ogg"}
    container = fmt_map.get(output_format, "mp3")

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "s16le",
        "-ar", str(sample_rate),
        "-ac", "1",
        "-i", "pipe:0",
        "-acodec", codec,
        "-f", container,
        "pipe:1",
    ]

    proc = subprocess.run(cmd, input=raw_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if proc.returncode != 0:
        logger.error("ffmpeg encode failed: %s", proc.stderr.decode(errors="ignore"))
        raise RuntimeError("Audio encoding failed")

    return proc.stdout
PYEOF

ok "Wrote shared/audio_assembler.py"

# ------------------------------------------------------------------------------
# STEP 09 — Shared metrics
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/metrics.py" <<'PYEOF'
from prometheus_client import Counter, Histogram, Gauge

tts_requests_total = Counter(
    "tts_requests_total",
    "Total TTS requests",
    ["engine", "status", "language"],
)

tts_synthesis_duration = Histogram(
    "tts_synthesis_duration_seconds",
    "Total synthesis duration",
    ["engine"],
    buckets=[1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300, float("inf")],
)

tts_chunk_duration = Histogram(
    "tts_chunk_duration_seconds",
    "Per-chunk synthesis duration",
    ["engine", "language"],
    buckets=[0.5, 1, 2, 5, 10, 20, 30, 60, float("inf")],
)

tts_queue_wait = Histogram(
    "tts_queue_wait_seconds",
    "Time waiting in queue",
    ["engine"],
    buckets=[0.1, 0.5, 1, 2, 5, 10, 30, 60, 120, 300],
)

tts_active_syntheses = Gauge(
    "tts_active_syntheses",
    "Currently synthesizing",
    ["engine"],
)

tts_queue_depth = Gauge(
    "tts_queue_depth",
    "Requests waiting in queue",
    ["engine"],
)

tts_cancelled_total = Counter(
    "tts_cancelled_requests_total",
    "Cancelled requests",
    ["engine", "reason"],
)

tts_cache_hits = Counter(
    "tts_cache_hits_total",
    "Cache hits",
    ["engine"],
)

tts_cache_misses = Counter(
    "tts_cache_misses_total",
    "Cache misses",
    ["engine"],
)

tts_chunk_count = Histogram(
    "tts_chunk_count",
    "Chunks per request",
    ["engine"],
    buckets=[1, 2, 3, 5, 8, 12, 20, 40],
)

tts_model_loaded = Gauge(
    "tts_model_loaded",
    "Model loaded (1=yes)",
    ["engine"],
)

tts_rtf = Histogram(
    "tts_realtime_factor",
    "Synthesis time / audio duration",
    ["engine"],
    buckets=[0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0],
)

tts_input_chars = Histogram(
    "tts_input_characters",
    "Input character count",
    ["engine"],
    buckets=[50, 100, 150, 200, 250, 500, 1000, 2000, 5000],
)

tts_output_audio_seconds = Histogram(
    "tts_output_audio_seconds",
    "Generated audio duration",
    ["engine"],
    buckets=[1, 2, 5, 10, 20, 30, 60, 120, 300],
)

tts_cgroup_cpu_quota = Gauge(
    "tts_cgroup_cpu_quota_cores",
    "Effective cgroup CPU quota",
    ["engine"],
)

tts_cgroup_throttled_seconds = Gauge(
    "tts_cgroup_throttled_seconds_total",
    "Cgroup CPU throttled seconds",
    ["engine"],
)

tts_resource_contract_valid = Gauge(
    "tts_resource_contract_valid",
    "1 if runtime matches fixed contract",
    ["engine"],
)
PYEOF

ok "Wrote shared/metrics.py"

# ------------------------------------------------------------------------------
# STEP 10 — Shared cgroup probe
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/shared/cgroup_probe.py" <<'PYEOF'
"""Read-only cgroup inspection for metrics. This does NOT allocate or adjust
CPU/RAM — it only verifies that the fixed contract (.env.resources) matches
what the container runtime is actually enforcing."""

import logging
import math
import os

logger = logging.getLogger(__name__)


def read_cpu_quota_cores() -> float:
    path_v2 = "/sys/fs/cgroup/cpu.max"

    if os.path.exists(path_v2):
        try:
            with open(path_v2) as f:
                quota, period = f.read().strip().split()

            if quota == "max":
                return float(os.cpu_count() or 1)

            return int(quota) / int(period)
        except Exception:
            pass

    quota_path = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
    period_path = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"

    if os.path.exists(quota_path):
        try:
            with open(quota_path) as f:
                quota = int(f.read().strip())

            with open(period_path) as f:
                period = int(f.read().strip())

            if quota > 0:
                return quota / period
        except Exception:
            pass

    return float(os.cpu_count() or 1)


def read_throttled_seconds() -> float:
    stat_path = "/sys/fs/cgroup/cpu.stat"

    if os.path.exists(stat_path):
        try:
            with open(stat_path) as f:
                for line in f:
                    if line.startswith("throttled_usec"):
                        return int(line.split()[1]) / 1_000_000
        except Exception:
            pass

    return 0.0


def read_memory_current_mb() -> float:
    path = "/sys/fs/cgroup/memory.current"

    if os.path.exists(path):
        try:
            with open(path) as f:
                return int(f.read().strip()) / (1024 * 1024)
        except Exception:
            pass

    return 0.0


def validate_contract(expected_cpus: float, tolerance: float = 0.5) -> bool:
    actual = read_cpu_quota_cores()
    valid = abs(actual - expected_cpus) <= tolerance

    if not valid:
        logger.warning(
            "Resource contract mismatch: expected %.1f vCPU, cgroup reports %.2f",
            expected_cpus,
            actual,
        )

    return valid
PYEOF

ok "Wrote shared/cgroup_probe.py"

# ------------------------------------------------------------------------------
# STEP 11 — Router
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/router/main.py" <<'PYEOF'
"""TTS API v4.0 Router. Validates, plans, routes, caches. n8n sends complete
text ONCE — all splitting/normalization happens here, not in n8n."""

import hashlib
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import httpx
import redis.asyncio as aioredis

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

sys.path.insert(0, "/app/shared")

from languages import registry  # noqa: E402
from metrics import tts_cache_hits, tts_cache_misses, tts_requests_total  # noqa: E402
from models import TTSRequest  # noqa: E402
from text_planner import build_plan  # noqa: E402

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

REDIS_URL = os.getenv("REDIS_URL", "redis://tts-redis:6379/0")
API_SECRET_KEY = os.getenv("API_SECRET_KEY", "")

AR_ENGINE_URL = os.getenv("AR_ENGINE_URL", "http://tts-api-ar:5072")
EN_ENGINE_URL = os.getenv("EN_ENGINE_URL", "http://tts-api-en:5070")

CACHE_ENABLED = os.getenv("CACHE_ENABLED", "true").lower() == "true"
CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_HOURS", "24")) * 3600
CACHE_NAMESPACE = os.getenv("CACHE_NAMESPACE_VERSION", "v4")

PLANNER_VERSION = os.getenv("PLANNER_VERSION", "1")
NORMALIZER_VERSION = os.getenv("NORMALIZER_VERSION", "1")
ASSEMBLER_VERSION = os.getenv("ASSEMBLER_VERSION", "1")

redis_client: Optional[aioredis.Redis] = None
http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client, http_client

    try:
        redis_client = aioredis.from_url(REDIS_URL, decode_responses=False)
        await redis_client.ping()
        logger.info("Router Redis connected (namespace=%s)", CACHE_NAMESPACE)
    except Exception as e:
        logger.warning("Router Redis not available: %s", e)
        redis_client = None

    http_client = httpx.AsyncClient(timeout=350.0)

    yield

    if redis_client:
        await redis_client.close()

    if http_client:
        await http_client.aclose()


app = FastAPI(title="TTS API v4.0 Router", version="4.0.2", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "*").split(","),
    allow_methods=["*"],
    allow_headers=["*"],
)


async def verify_api_key(x_api_key: Optional[str] = Header(None)):
    if not API_SECRET_KEY:
        return

    if x_api_key is None or x_api_key != API_SECRET_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def make_cache_key(req: TTSRequest, engine: str) -> str:
    """v4 cache key includes planner/normalizer/assembler versions so a
    pipeline change can NEVER silently serve stale audio from the old
    splitting/assembly logic."""

    raw = "|".join([
        CACHE_NAMESPACE,
        engine,
        req.text,
        req.language,
        req.voice_id or "",
        req.output_format,
        str(req.speed),
        str(req.pitch),
        str(req.normalize),
        PLANNER_VERSION,
        NORMALIZER_VERSION,
        ASSEMBLER_VERSION,
    ])

    digest = hashlib.sha256(raw.encode()).hexdigest()
    return f"tts:{CACHE_NAMESPACE}:audio:{digest}"


async def cache_get(key: str) -> Optional[bytes]:
    if not redis_client or not CACHE_ENABLED:
        return None

    try:
        return await redis_client.get(key)
    except Exception:
        return None


async def cache_set(key: str, data: bytes, ttl: int = CACHE_TTL_SECONDS):
    if not redis_client or not CACHE_ENABLED:
        return

    try:
        await redis_client.setex(key, ttl, data)
    except Exception as e:
        logger.warning("Cache set failed: %s", e)


CONTENT_TYPES = {
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
    "ogg": "audio/ogg",
}


@app.post("/v1/text-to-speech")
async def text_to_speech(request: Request, tts_req: TTSRequest, _=Depends(verify_api_key)):
    request_id = str(uuid.uuid4())
    start_time = time.monotonic()

    spec = registry.resolve(tts_req.language)

    if spec is None:
        tts_requests_total.labels(engine="none", status="unsupported_language", language=tts_req.language).inc()

        raise HTTPException(
            status_code=422,
            detail={
                "code": "unsupported_language",
                "requested_language": tts_req.language,
                "supported_languages": registry.supported_codes(),
                "message": f"'{tts_req.language}' is not currently supported by this deployment.",
            },
        )

    engine = "ar" if spec.engine == "xtts_arabic" else "en"

    try:
        plan = build_plan(tts_req.text, tts_req.language)
    except ValueError as e:
        raise HTTPException(status_code=422, detail={"code": "planning_failed", "message": str(e)})

    if not plan:
        raise HTTPException(status_code=422, detail={"code": "empty_text", "message": "No synthesizable text after normalization."})

    logger.info("[%s] lang=%s engine=%s chars=%d chunks=%d", request_id, spec.code, engine, len(tts_req.text), len(plan))

    cache_key = make_cache_key(tts_req, engine)
    cached = await cache_get(cache_key)

    if cached:
        tts_cache_hits.labels(engine=engine).inc()
        tts_requests_total.labels(engine=engine, status="cache_hit", language=spec.code).inc()

        content_type = CONTENT_TYPES.get(tts_req.output_format, "audio/mpeg")

        return Response(
            content=cached,
            media_type=content_type,
            headers={
                "X-Cache-Status": "HIT",
                "X-Request-ID": request_id,
                "X-Engine": engine,
            },
        )

    tts_cache_misses.labels(engine=engine).inc()

    engine_url = AR_ENGINE_URL if engine == "ar" else EN_ENGINE_URL

    try:
        if await request.is_disconnected():
            return Response(status_code=499)

        resp = await http_client.post(
            f"{engine_url}/synthesize",
            json={
                "request_id": request_id,
                "chunks": [c.model_dump() for c in plan],
                "voice_id": tts_req.voice_id,
                "output_format": tts_req.output_format,
                "speed": tts_req.speed,
                "pitch": tts_req.pitch,
                "normalize": tts_req.normalize,
            },
            headers={"X-Request-ID": request_id},
        )

        if resp.status_code == 200:
            audio_data = resp.content
            elapsed = time.monotonic() - start_time
            content_type = CONTENT_TYPES.get(tts_req.output_format, "audio/mpeg")

            await cache_set(cache_key, audio_data)

            tts_requests_total.labels(engine=engine, status="success", language=spec.code).inc()

            return Response(
                content=audio_data,
                media_type=content_type,
                headers={
                    "X-Cache-Status": "MISS",
                    "X-Request-ID": request_id,
                    "X-Engine": engine,
                    "X-Synthesis-Time": f"{elapsed:.2f}s",
                    "X-Chunks": str(len(plan)),
                },
            )

        elif resp.status_code == 503:
            tts_requests_total.labels(engine=engine, status="queue_full", language=spec.code).inc()

            return JSONResponse(
                status_code=503,
                content={"detail": "Engine queue full", "engine": engine},
                headers={"Retry-After": resp.headers.get("Retry-After", "15")},
            )

        else:
            tts_requests_total.labels(engine=engine, status="error", language=spec.code).inc()
            raise HTTPException(status_code=resp.status_code, detail="Engine error")

    except httpx.TimeoutException:
        tts_requests_total.labels(engine=engine, status="timeout", language=spec.code).inc()
        raise HTTPException(status_code=504, detail="Engine synthesis timeout")

    except httpx.ConnectError:
        tts_requests_total.labels(engine=engine, status="engine_unavailable", language=spec.code).inc()
        raise HTTPException(status_code=503, detail=f"Engine {engine} unavailable")


@app.get("/v1/languages")
async def list_languages():
    return {"languages": registry.supported_codes()}


@app.get("/health")
async def health():
    redis_ok = False

    if redis_client:
        try:
            await redis_client.ping()
            redis_ok = True
        except Exception:
            pass

    return {
        "status": "healthy",
        "redis": redis_ok,
        "cache_namespace": CACHE_NAMESPACE,
        "version": "4.0.2",
    }


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
PYEOF

ok "Wrote router/main.py (rejects unsupported languages, v4 cache namespace)"

# ------------------------------------------------------------------------------
# STEP 12 — Arabic XTTS engine
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/arabic/tts_engine.py" <<'PYEOF'
"""XTTS-v2 wrapper with self-healing Arabic voice preparation.
If master_embedding.pt is absent, it creates it from existing reference clips.
If clips are absent too, it runs the bundled v3-Step-05-equivalent provisioner
inside this container, then builds and persistently saves the embedding."""

import logging
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)

XTTS_SAMPLE_RATE = 24000


class XTTSEngine:
    def __init__(self, embedding_path: str, clips_dir: str = "/app/voices/arabic/reference_clips"):
        self.embedding_path = Path(embedding_path)
        self.clips_dir = Path(clips_dir)
        self.tts = None
        self.speaker_embedding = None
        self.gpt_cond_latent = None
        self.is_loaded = False

    def load(self) -> None:
        import torch

        original_torch_load = torch.load

        def patched_load(*args, **kwargs):
            kwargs.setdefault("weights_only", False)
            return original_torch_load(*args, **kwargs)

        torch.load = patched_load

        try:
            t0 = time.monotonic()

            from TTS.api import TTS

            self.tts = TTS(model_name="tts_models/multilingual/multi-dataset/xtts_v2", gpu=False)

            logger.info("XTTS-v2 base model loaded in %.1fs", time.monotonic() - t0)
        finally:
            torch.load = original_torch_load

        if not self.embedding_path.exists():
            self._ensure_reference_clips()
            self._build_embedding_from_clips()

        self._load_embedding()
        self.is_loaded = True

    def _ensure_reference_clips(self) -> None:
        clips = list(self.clips_dir.glob("*.wav")) + list(self.clips_dir.glob("*.WAV"))

        if clips:
            logger.info("Using %d existing Arabic reference clips", len(clips))
            return

        provisioner = "/app/scripts/provision_arabic_reference_clips.py"

        if not os.path.exists(provisioner):
            raise RuntimeError("No Arabic reference clips and bundled provisioner is unavailable")

        logger.info("No Arabic clips found; downloading corpus and selecting clips automatically")

        subprocess.run(
            [
                sys.executable,
                provisioner,
                "--target", str(self.clips_dir),
                "--stats", str(self.clips_dir.parent / "corpus_stats.json"),
                "--url", os.getenv("ARABIC_CORPUS_URL", "https://en.arabicspeechcorpus.com/arabic-speech-corpus.zip"),
            ],
            check=True,
        )

        clips = list(self.clips_dir.glob("*.wav")) + list(self.clips_dir.glob("*.WAV"))

        if not clips:
            raise RuntimeError("Corpus provisioner completed without reference clips")

    def _build_embedding_from_clips(self) -> None:
        """Builds averaged XTTS conditioning latents and atomically persists
        master_embedding.pt. Called only at first startup when it is missing."""

        import torch

        clips = sorted(list(self.clips_dir.glob("*.wav")) + list(self.clips_dir.glob("*.WAV")))[:50]

        if not clips:
            raise RuntimeError("Cannot build Arabic embedding: no reference clips")

        embeddings, gpt_latents = [], []

        logger.info("Building Arabic master embedding from %d clips", len(clips))

        for i, clip in enumerate(clips, 1):
            try:
                gpt, speaker = self.tts.synthesizer.tts_model.get_conditioning_latents(
                    audio_path=[str(clip)],
                    max_ref_length=30,
                    gpt_cond_len=30,
                    gpt_cond_chunk_len=4,
                )

                embeddings.append(speaker.detach().cpu())
                gpt_latents.append(gpt.detach().cpu())

                if i % 10 == 0 or i == len(clips):
                    logger.info("Encoded Arabic reference clip %d/%d", i, len(clips))

            except Exception as exc:
                logger.warning("Skipping unusable reference clip %s: %s", clip.name, exc)

        if not embeddings:
            raise RuntimeError("No usable Arabic clips; cannot build master embedding")

        self.embedding_path.parent.mkdir(parents=True, exist_ok=True)

        temp_path = self.embedding_path.with_suffix(".pt.tmp")

        torch.save(
            {
                "speaker_embedding": torch.stack(embeddings).mean(dim=0),
                "gpt_cond_latent": torch.stack(gpt_latents).mean(dim=0),
                "info": {
                    "clips_used": len(embeddings),
                    "source": "Arabic Speech Corpus",
                    "built_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                },
            },
            temp_path,
        )

        os.replace(temp_path, self.embedding_path)

        logger.info("Arabic master embedding saved: %s (%d clips)", self.embedding_path, len(embeddings))

    def _load_embedding(self) -> None:
        import torch

        data = torch.load(self.embedding_path, map_location="cpu", weights_only=False)

        self.speaker_embedding = data["speaker_embedding"]
        self.gpt_cond_latent = data["gpt_cond_latent"]

        logger.info("Loaded Arabic master embedding from %s", self.embedding_path)

    def synthesize_chunk(self, text: str, speed: float = 1.0) -> np.ndarray:
        if not self.is_loaded:
            raise RuntimeError("Engine not loaded")

        wav = self.tts.synthesizer.tts_model.inference(
            text=text,
            language="ar",
            gpt_cond_latent=self.gpt_cond_latent,
            speaker_embedding=self.speaker_embedding,
            speed=speed,
            enable_text_splitting=False,
        )["wav"]

        return np.array(wav, dtype=np.float32)

    def synthesize_warmup(self) -> None:
        self.synthesize_chunk("مرحباً", speed=1.0)
PYEOF

cat > "$INSTALL_DIR/app/arabic/main.py" <<'PYEOF'
"""TTS API v4.0 Arabic Engine (XTTS-v2). Exactly ONE model process, ONE
Uvicorn worker, ONE executor thread, ONE concurrent synthesis. PyTorch
threads are set ONCE at startup — never per-request, never per-chunk."""

import asyncio
import logging
import os
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

sys.path.insert(0, "/app/arabic")
sys.path.insert(0, "/app/shared")

from audio_assembler import AudioAssembler, ChunkResult, encode_pcm_to_bytes  # noqa: E402
from cgroup_probe import read_cpu_quota_cores, read_throttled_seconds, validate_contract  # noqa: E402
from metrics import (  # noqa: E402
    tts_active_syntheses,
    tts_cancelled_total,
    tts_cgroup_cpu_quota,
    tts_cgroup_throttled_seconds,
    tts_chunk_count,
    tts_chunk_duration,
    tts_input_chars,
    tts_model_loaded,
    tts_output_audio_seconds,
    tts_queue_depth,
    tts_queue_wait,
    tts_requests_total,
    tts_resource_contract_valid,
    tts_rtf,
    tts_synthesis_duration,
)
from models import HealthResponse, SynthesizeRequest  # noqa: E402
from tts_engine import XTTS_SAMPLE_RATE, XTTSEngine  # noqa: E402

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

ENGINE_NAME = "ar"

AR_THREADS = int(os.getenv("AR_THREADS", "6"))
AR_CONCURRENT = int(os.getenv("AR_CONCURRENT", "1"))
AR_EXECUTOR_WORKERS = int(os.getenv("AR_EXECUTOR_WORKERS", "1"))
AR_CPUS = float(os.getenv("AR_CPUS", "6.0"))

MAX_QUEUE_DEPTH = int(os.getenv("AR_MAX_QUEUE_DEPTH", "20"))
QUEUE_TIMEOUT = float(os.getenv("AR_QUEUE_TIMEOUT_SECONDS", "300"))
ORPHAN_TIMEOUT = float(os.getenv("AR_ORPHAN_TIMEOUT_SECONDS", "180"))

EMBEDDING_PATH = os.getenv("AR_EMBEDDING_PATH", "/app/voices/arabic/master_embedding.pt")

tts_engine: Optional[XTTSEngine] = None
executor: Optional[ThreadPoolExecutor] = None
synthesis_semaphore: Optional[asyncio.Semaphore] = None

request_queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_QUEUE_DEPTH)

active_count = 0
queue_count = 0


def configure_torch_once() -> None:
    """The ONLY place torch.set_num_threads() is ever called in this
    service. Must run before model load, before warm-up, before any
    inference. Never called again for the lifetime of the process."""

    import torch

    torch.set_num_threads(AR_THREADS)
    torch.set_num_interop_threads(1)

    logger.info(
        "Arabic runtime initialized ONCE: torch_threads=%d interop_threads=%d",
        torch.get_num_threads(),
        torch.get_num_interop_threads(),
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    global tts_engine, executor, synthesis_semaphore

    configure_torch_once()

    contract_valid = validate_contract(expected_cpus=AR_CPUS)
    tts_resource_contract_valid.labels(engine=ENGINE_NAME).set(1 if contract_valid else 0)
    tts_cgroup_cpu_quota.labels(engine=ENGINE_NAME).set(read_cpu_quota_cores())

    executor = ThreadPoolExecutor(max_workers=AR_EXECUTOR_WORKERS)
    synthesis_semaphore = asyncio.Semaphore(AR_CONCURRENT)

    logger.info("Arabic engine loading XTTS-v2 model...")

    tts_engine = XTTSEngine(
        embedding_path=EMBEDDING_PATH,
        clips_dir=os.getenv("AR_REFERENCE_CLIPS_DIR", "/app/voices/arabic/reference_clips"),
    )

    await asyncio.get_running_loop().run_in_executor(executor, tts_engine.load)

    tts_model_loaded.labels(engine=ENGINE_NAME).set(1)

    logger.info("Arabic engine model loaded")

    try:
        await asyncio.get_running_loop().run_in_executor(executor, tts_engine.synthesize_warmup)
        logger.info("Arabic engine warm-up complete")
    except Exception as e:
        logger.warning("Arabic warm-up failed (non-fatal): %s", e)

    yield

    if executor:
        executor.shutdown(wait=False)

    tts_model_loaded.labels(engine=ENGINE_NAME).set(0)


app = FastAPI(title="TTS API v4.0 Arabic Engine", version="4.0.2", lifespan=lifespan)


async def drain_queue():
    try:
        item = request_queue.get_nowait()
        item["event"].set()
    except asyncio.QueueEmpty:
        pass


@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest, request: Request):
    global active_count, queue_count

    request_id = req.request_id or str(uuid.uuid4())

    if await request.is_disconnected():
        tts_cancelled_total.labels(engine=ENGINE_NAME, reason="disconnect_before_queue").inc()
        return Response(status_code=499)

    # The semaphore is the single concurrency authority. Queue counters are
    # observability only; they never decide whether a request may synthesize.
    if synthesis_semaphore.locked() and request_queue.full():
        return JSONResponse(
            status_code=503,
            content={"detail": "Queue full", "engine": ENGINE_NAME},
            headers={"Retry-After": "15"},
        )

    waiting = synthesis_semaphore.locked()
    queue_start = time.monotonic()

    if waiting:
        queue_count += 1
        tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

    try:
        await asyncio.wait_for(synthesis_semaphore.acquire(), timeout=QUEUE_TIMEOUT)
    except asyncio.TimeoutError:
        if waiting:
            queue_count -= 1
            tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

        tts_cancelled_total.labels(engine=ENGINE_NAME, reason="queue_timeout").inc()

        return JSONResponse(
            status_code=503,
            content={"detail": "Queue wait timeout"},
            headers={"Retry-After": "30"},
        )

    if waiting:
        queue_count -= 1
        tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

    tts_queue_wait.labels(engine=ENGINE_NAME).observe(time.monotonic() - queue_start)

    active_count += 1
    tts_active_syntheses.labels(engine=ENGINE_NAME).set(active_count)

    synthesis_start = time.monotonic()

    try:
        if await request.is_disconnected():
            tts_cancelled_total.labels(engine=ENGINE_NAME, reason="disconnect_before_synthesis").inc()
            return Response(status_code=499)

        tts_input_chars.labels(engine=ENGINE_NAME).observe(sum(len(c.text) for c in req.chunks))
        tts_chunk_count.labels(engine=ENGINE_NAME).observe(len(req.chunks))

        loop = asyncio.get_running_loop()

        assembler = AudioAssembler(sample_rate=XTTS_SAMPLE_RATE)

        for i, chunk in enumerate(req.chunks):
            if await request.is_disconnected():
                tts_cancelled_total.labels(engine=ENGINE_NAME, reason=f"disconnect_chunk_{i}").inc()
                return Response(status_code=499)

            chunk_start = time.monotonic()

            try:
                pcm = await asyncio.wait_for(
                    loop.run_in_executor(executor, tts_engine.synthesize_chunk, chunk.text, req.speed),
                    timeout=ORPHAN_TIMEOUT,
                )
            except asyncio.TimeoutError:
                tts_cancelled_total.labels(engine=ENGINE_NAME, reason="orphan_timeout").inc()
                raise HTTPException(status_code=504, detail="Chunk synthesis timeout")

            tts_chunk_duration.labels(engine=ENGINE_NAME, language="ar").observe(time.monotonic() - chunk_start)

            assembler.append(ChunkResult(pcm=pcm, sample_rate=XTTS_SAMPLE_RATE, pause_ms=chunk.pause_ms))

        final_pcm, sample_rate = assembler.finalize(normalize=req.normalize)
        audio_bytes = encode_pcm_to_bytes(final_pcm, sample_rate, req.output_format)

        elapsed = time.monotonic() - synthesis_start
        audio_seconds = len(final_pcm) / sample_rate

        tts_synthesis_duration.labels(engine=ENGINE_NAME).observe(elapsed)
        tts_output_audio_seconds.labels(engine=ENGINE_NAME).observe(audio_seconds)

        if audio_seconds > 0:
            tts_rtf.labels(engine=ENGINE_NAME).observe(elapsed / audio_seconds)

        tts_requests_total.labels(engine=ENGINE_NAME, status="success", language="ar").inc()
        tts_cgroup_throttled_seconds.labels(engine=ENGINE_NAME).set(read_throttled_seconds())

        content_types = {
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "ogg": "audio/ogg",
        }

        return Response(
            content=audio_bytes,
            media_type=content_types.get(req.output_format, "audio/mpeg"),
            headers={
                "X-Request-ID": request_id,
                "X-Synthesis-Time": f"{elapsed:.2f}s",
                "X-Chunks": str(len(req.chunks)),
                "X-Engine": "xtts-v2-ar",
            },
        )

    except HTTPException:
        raise

    except Exception as e:
        tts_requests_total.labels(engine=ENGINE_NAME, status="error", language="ar").inc()
        logger.error("[%s] Synthesis error: %s", request_id, e, exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        active_count -= 1
        tts_active_syntheses.labels(engine=ENGINE_NAME).set(active_count)
        synthesis_semaphore.release()


@app.get("/health")
async def health():
    contract_valid = validate_contract(expected_cpus=AR_CPUS)

    return {
        "status": "healthy",
        "engine": "xtts-v2-ar",
        "model_loaded": tts_engine.is_loaded if tts_engine else False,
        "active_syntheses": active_count,
        "queue_depth": queue_count,
        "resource_contract_valid": contract_valid,
        "cgroup_cpu_quota": read_cpu_quota_cores(),
        "version": "4.0.2",
    }


@app.get("/ready")
async def ready():
    if not tts_engine or not tts_engine.is_loaded:
        raise HTTPException(status_code=503, detail="Model not loaded")

    return {"status": "ready", "engine": "xtts-v2-ar"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
PYEOF

ok "Wrote arabic/main.py + tts_engine.py (single worker, single thread-set)"

# ------------------------------------------------------------------------------
# STEP 13 — Kokoro multilingual engine
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/app/multilingual/main.py" <<'PYEOF'
"""TTS API v4.0 Kokoro Engine. Receives ONLY pre-validated, registry-approved
non-Arabic chunks from the router. Never receives Arabic text."""

import asyncio
import logging
import os
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

sys.path.insert(0, "/app/multilingual")
sys.path.insert(0, "/app/shared")

from audio_assembler import AudioAssembler, ChunkResult, encode_pcm_to_bytes  # noqa: E402
from metrics import (  # noqa: E402
    tts_active_syntheses,
    tts_cancelled_total,
    tts_chunk_count,
    tts_chunk_duration,
    tts_model_loaded,
    tts_output_audio_seconds,
    tts_queue_depth,
    tts_queue_wait,
    tts_requests_total,
    tts_rtf,
    tts_synthesis_duration,
)
from models import SynthesizeRequest  # noqa: E402
from tts_engine import KOKORO_SAMPLE_RATE, KokoroEngine  # noqa: E402

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

ENGINE_NAME = "en"

EN_THREADS = int(os.getenv("EN_THREADS", "2"))
EN_CONCURRENT = int(os.getenv("EN_CONCURRENT", "4"))

MAX_QUEUE_DEPTH = int(os.getenv("EN_MAX_QUEUE_DEPTH", "40"))
QUEUE_TIMEOUT = float(os.getenv("EN_QUEUE_TIMEOUT_SECONDS", "120"))
ORPHAN_TIMEOUT = float(os.getenv("EN_ORPHAN_TIMEOUT_SECONDS", "30"))

DEFAULT_VOICE = os.getenv("EN_DEFAULT_VOICE", "af_heart")

tts_engine: Optional[KokoroEngine] = None
executor: Optional[ThreadPoolExecutor] = None
synthesis_semaphore: Optional[asyncio.Semaphore] = None

request_queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_QUEUE_DEPTH)

active_count = 0
queue_count = 0


def configure_torch_once() -> None:
    try:
        import torch

        torch.set_num_threads(EN_THREADS)

        logger.info("Kokoro runtime initialized ONCE: torch_threads=%d", torch.get_num_threads())
    except ImportError:
        pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    global tts_engine, executor, synthesis_semaphore

    configure_torch_once()

    executor = ThreadPoolExecutor(max_workers=EN_CONCURRENT)
    synthesis_semaphore = asyncio.Semaphore(EN_CONCURRENT)

    logger.info("Kokoro engine loading model...")

    tts_engine = KokoroEngine(default_voice=DEFAULT_VOICE)

    await asyncio.get_running_loop().run_in_executor(executor, tts_engine.load)

    tts_model_loaded.labels(engine=ENGINE_NAME).set(1)

    logger.info("Kokoro engine model loaded")

    try:
        await asyncio.get_running_loop().run_in_executor(executor, tts_engine.synthesize_warmup)
    except Exception as e:
        logger.warning("Kokoro warm-up failed: %s", e)

    yield

    if executor:
        executor.shutdown(wait=False)

    tts_model_loaded.labels(engine=ENGINE_NAME).set(0)


app = FastAPI(title="TTS API v4.0 Kokoro Engine", version="4.0.2", lifespan=lifespan)


async def drain_queue():
    try:
        item = request_queue.get_nowait()
        item["event"].set()
    except asyncio.QueueEmpty:
        pass


@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest, request: Request):
    global active_count, queue_count

    request_id = req.request_id or str(uuid.uuid4())

    if any(c.language == "ar" for c in req.chunks):
        raise HTTPException(status_code=422, detail="Kokoro must not receive Arabic text")

    if await request.is_disconnected():
        return Response(status_code=499)

    acquired_immediately = active_count < EN_CONCURRENT

    if not acquired_immediately:
        if request_queue.full():
            return JSONResponse(
                status_code=503,
                content={"detail": "Queue full", "engine": ENGINE_NAME},
                headers={"Retry-After": "5"},
            )

        queue_event = asyncio.Event()

        await request_queue.put({"request_id": request_id, "event": queue_event})

        queue_count += 1
        tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

        queue_start = time.monotonic()

        try:
            await asyncio.wait_for(queue_event.wait(), timeout=QUEUE_TIMEOUT)
        except asyncio.TimeoutError:
            queue_count -= 1
            tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

            return JSONResponse(
                status_code=503,
                content={"detail": "Queue timeout"},
                headers={"Retry-After": "10"},
            )

        tts_queue_wait.labels(engine=ENGINE_NAME).observe(time.monotonic() - queue_start)

        queue_count -= 1
        tts_queue_depth.labels(engine=ENGINE_NAME).set(queue_count)

    async with synthesis_semaphore:
        active_count += 1
        tts_active_syntheses.labels(engine=ENGINE_NAME).set(active_count)

        start = time.monotonic()

        try:
            if await request.is_disconnected():
                return Response(status_code=499)

            voice = req.voice_id or DEFAULT_VOICE

            loop = asyncio.get_running_loop()

            assembler = AudioAssembler(sample_rate=KOKORO_SAMPLE_RATE)

            tts_chunk_count.labels(engine=ENGINE_NAME).observe(len(req.chunks))

            for chunk in req.chunks:
                if await request.is_disconnected():
                    return Response(status_code=499)

                chunk_start = time.monotonic()

                try:
                    pcm = await asyncio.wait_for(
                        loop.run_in_executor(
                            executor,
                            tts_engine.synthesize_chunk,
                            chunk.text,
                            voice,
                            chunk.language,
                            req.speed,
                        ),
                        timeout=ORPHAN_TIMEOUT,
                    )
                except asyncio.TimeoutError:
                    tts_cancelled_total.labels(engine=ENGINE_NAME, reason="orphan_timeout").inc()
                    raise HTTPException(status_code=504, detail="Chunk timeout")

                tts_chunk_duration.labels(engine=ENGINE_NAME, language=chunk.language).observe(time.monotonic() - chunk_start)

                assembler.append(ChunkResult(pcm=pcm, sample_rate=KOKORO_SAMPLE_RATE, pause_ms=chunk.pause_ms))

            final_pcm, sample_rate = assembler.finalize(normalize=req.normalize)
            audio_bytes = encode_pcm_to_bytes(final_pcm, sample_rate, req.output_format)

            elapsed = time.monotonic() - start
            audio_seconds = len(final_pcm) / sample_rate

            tts_synthesis_duration.labels(engine=ENGINE_NAME).observe(elapsed)
            tts_output_audio_seconds.labels(engine=ENGINE_NAME).observe(audio_seconds)

            if audio_seconds > 0:
                tts_rtf.labels(engine=ENGINE_NAME).observe(elapsed / audio_seconds)

            tts_requests_total.labels(engine=ENGINE_NAME, status="success", language=req.chunks[0].language).inc()

            content_types = {
                "mp3": "audio/mpeg",
                "wav": "audio/wav",
                "ogg": "audio/ogg",
            }

            return Response(
                content=audio_bytes,
                media_type=content_types.get(req.output_format, "audio/mpeg"),
                headers={
                    "X-Request-ID": request_id,
                    "X-Synthesis-Time": f"{elapsed:.2f}s",
                    "X-Chunks": str(len(req.chunks)),
                    "X-Engine": "kokoro-en",
                },
            )

        except HTTPException:
            raise

        except Exception as e:
            tts_requests_total.labels(engine=ENGINE_NAME, status="error", language="unknown").inc()
            logger.error("[%s] Error: %s", request_id, e, exc_info=True)
            raise HTTPException(status_code=500, detail=str(e))

        finally:
            active_count -= 1
            tts_active_syntheses.labels(engine=ENGINE_NAME).set(active_count)

            asyncio.create_task(drain_queue())


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "engine": "kokoro-en",
        "model_loaded": tts_engine.is_loaded if tts_engine else False,
        "active_syntheses": active_count,
        "queue_depth": queue_count,
        "version": "4.0.2",
    }


@app.get("/ready")
async def ready():
    if not tts_engine or not tts_engine.is_loaded:
        raise HTTPException(status_code=503, detail="Model not loaded")

    return {"status": "ready", "engine": "kokoro-en"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
PYEOF

cat > "$INSTALL_DIR/app/multilingual/tts_engine.py" <<'PYEOF'
import logging
import time
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)

KOKORO_SAMPLE_RATE = 24000

_LANG_MAP = {
    "en": "a",
    "en-us": "a",
    "en-gb": "b",
    "fr": "f",
    "de": "d",
    "es": "e",
    "pt": "p",
    "ja": "j",
    "ko": "k",
    "zh": "z",
}


class KokoroEngine:
    def __init__(self, default_voice: str = "af_heart"):
        self.default_voice = default_voice
        self.pipeline = None
        self.is_loaded = False

    def load(self) -> None:
        from kokoro import KPipeline

        t0 = time.monotonic()

        self.pipeline = KPipeline(lang_code="a")
        self.is_loaded = True

        logger.info("Kokoro KPipeline loaded in %.1fs", time.monotonic() - t0)

    def synthesize_chunk(self, text: str, voice: Optional[str], language: str, speed: float = 1.0) -> np.ndarray:
        if not self.is_loaded:
            raise RuntimeError("Kokoro engine not loaded")

        self.pipeline.lang_code = _LANG_MAP.get(language.lower(), "a")

        chunks = []

        for _, _, audio in self.pipeline(text, voice=voice or self.default_voice, speed=speed):
            if audio is not None:
                chunks.append(np.array(audio, dtype=np.float32))

        if not chunks:
            raise RuntimeError("Kokoro returned empty audio")

        return np.concatenate(chunks) if len(chunks) > 1 else chunks[0]

    def synthesize_warmup(self) -> None:
        self.synthesize_chunk("Hello world", self.default_voice, "en-us", 1.0)
PYEOF

ok "Wrote multilingual/main.py + tts_engine.py"

# ------------------------------------------------------------------------------
# STEP 14 — Dockerfiles and requirements (FIXED FOR CPU + TRANSFORMERS PIN)
# ------------------------------------------------------------------------------

# Constraints file prevents TTS from pulling CUDA torch or transformers >= 4.42
cat > "$INSTALL_DIR/constraints.ar.txt" <<'REQEOF'
torch==2.5.1+cpu
torchaudio==2.5.1+cpu
numpy==1.26.4
transformers==4.41.2
REQEOF

cat > "$INSTALL_DIR/Dockerfile.ar" <<'DOCKEREOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ffmpeg \
    libsndfile1 \
    espeak-ng \
    wget \
    unzip \
    gcc \
    g++ \
    libgomp1 \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.ar.txt constraints.ar.txt /app/

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cpu \
    COQUI_TOS_AGREED=1

RUN pip install --upgrade pip

# Install CPU-only PyTorch stack first.
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu \
    torch==2.5.1+cpu \
    torchaudio==2.5.1+cpu

# Install TTS and API dependencies while forcing the CPU PyTorch stack and transformers pin.
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu \
    -c constraints.ar.txt \
    -r requirements.ar.txt

# Fail the build immediately if a CUDA torchaudio/torch was accidentally installed.
RUN python -c "import torch, torchaudio; print(torch.__version__, torchaudio.__version__); assert '+cpu' in torch.__version__; assert '+cpu' in torchaudio.__version__"

COPY app/arabic /app/arabic
COPY app/shared /app/shared
COPY scripts/provision_arabic_reference_clips.py /app/scripts/provision_arabic_reference_clips.py

ENV PYTHONPATH=/app:/app/arabic:/app/shared

EXPOSE 5072

CMD ["uvicorn", "arabic.main:app", "--host", "0.0.0.0", "--port", "5072", "--workers", "1", "--log-level", "info"]
DOCKEREOF

cat > "$INSTALL_DIR/Dockerfile.en" <<'DOCKEREOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ffmpeg \
    espeak-ng \
    gcc \
    g++ \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.en.txt /app/

RUN pip install --no-cache-dir -r requirements.en.txt

COPY app/multilingual /app/multilingual
COPY app/shared /app/shared

ENV PYTHONPATH=/app:/app/multilingual:/app/shared

EXPOSE 5070

CMD ["uvicorn", "multilingual.main:app", "--host", "0.0.0.0", "--port", "5070", "--workers", "1", "--log-level", "info"]
DOCKEREOF

cat > "$INSTALL_DIR/Dockerfile.router" <<'DOCKEREOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

COPY requirements.router.txt /app/

RUN pip install --no-cache-dir -r requirements.router.txt

COPY app/router /app/router
COPY app/shared /app/shared

ENV PYTHONPATH=/app:/app/router:/app/shared

EXPOSE 5073

CMD ["uvicorn", "router.main:app", "--host", "0.0.0.0", "--port", "5073", "--workers", "1", "--log-level", "info"]
DOCKEREOF

ok "Wrote Dockerfiles"

cat > "$INSTALL_DIR/requirements.ar.txt" <<'REQEOF'
--extra-index-url https://download.pytorch.org/whl/cpu

fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
prometheus-client==0.20.0
PyYAML==6.0.2

numpy==1.26.4
soundfile==0.12.1

# Pin transformers to fix BeamSearchScorer removal in >=4.42.0
transformers==4.41.2

# Coqui TTS / XTTS-v2
TTS==0.22.0
REQEOF

cat > "$INSTALL_DIR/requirements.en.txt" <<'REQEOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
prometheus-client==0.20.0
numpy==1.26.4
kokoro==0.9.4
misaki[en]==0.9.4
PyYAML==6.0.2
REQEOF

cat > "$INSTALL_DIR/requirements.router.txt" <<'REQEOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
prometheus-client==0.20.0
httpx==0.27.2
redis==5.0.8
PyYAML==6.0.2
REQEOF

ok "Wrote requirements files"

# ------------------------------------------------------------------------------
# STEP 15 — docker-compose.yml
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/docker-compose.yml" <<COMPOSEEOF
services:
  tts-redis:
    image: redis:7-alpine
    container_name: tts-v4-redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "\${REDIS_PASSWORD}", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    cpus: "${REDIS_CPUS}"
    mem_limit: "${REDIS_MEM_LIMIT}"
    networks: [tts-internal]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 15s
      timeout: 5s
      retries: 3

  tts-api-ar:
    build: {context: ., dockerfile: Dockerfile.ar}
    container_name: tts-v4-api-ar
    restart: unless-stopped
    environment:
      - AR_THREADS=${AR_THREADS}
      - AR_CONCURRENT=${AR_CONCURRENT}
      - AR_EXECUTOR_WORKERS=${AR_EXECUTOR_WORKERS}
      - AR_CPUS=${AR_CPUS}
      - OMP_NUM_THREADS=${AR_THREADS}
      - MKL_NUM_THREADS=${AR_THREADS}
      - OPENBLAS_NUM_THREADS=${AR_THREADS}
      - NUMEXPR_NUM_THREADS=${AR_THREADS}
      - AR_MAX_QUEUE_DEPTH=20
      - AR_QUEUE_TIMEOUT_SECONDS=300
      - AR_ORPHAN_TIMEOUT_SECONDS=180
      - AR_EMBEDDING_PATH=/app/voices/arabic/master_embedding.pt
      - AR_REFERENCE_CLIPS_DIR=/app/voices/arabic/reference_clips
      - ARABIC_CORPUS_URL=https://en.arabicspeechcorpus.com/arabic-speech-corpus.zip
      - LOG_LEVEL=INFO
      - COQUI_TOS_AGREED=1
    volumes:
      - ${INSTALL_DIR}/voices/arabic:/app/voices/arabic
      - ${INSTALL_DIR}/logs/arabic:/app/logs
    cpus: "${AR_CPUS}"
    mem_limit: "${AR_MEM_LIMIT}"
    networks: [tts-internal]
    depends_on:
      tts-redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5072/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 900s

  tts-api-en:
    build: {context: ., dockerfile: Dockerfile.en}
    container_name: tts-v4-api-en
    restart: unless-stopped
    environment:
      - EN_THREADS=${EN_THREADS}
      - EN_CONCURRENT=${EN_CONCURRENT}
      - EN_MAX_QUEUE_DEPTH=40
      - EN_QUEUE_TIMEOUT_SECONDS=120
      - EN_ORPHAN_TIMEOUT_SECONDS=30
      - EN_DEFAULT_VOICE=af_heart
      - LOG_LEVEL=INFO
    volumes:
      - ${INSTALL_DIR}/logs/multilingual:/app/logs
    cpus: "${EN_CPUS}"
    mem_limit: "${EN_MEM_LIMIT}"
    networks: [tts-internal]
    depends_on:
      tts-redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5070/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  tts-router:
    build: {context: ., dockerfile: Dockerfile.router}
    container_name: tts-v4-router
    restart: unless-stopped
    environment:
      - REDIS_URL=redis://:\${REDIS_PASSWORD}@tts-redis:6379/0
      - API_SECRET_KEY=\${API_SECRET_KEY}
      - AR_ENGINE_URL=http://tts-api-ar:5072
      - EN_ENGINE_URL=http://tts-api-en:5070
      - CACHE_ENABLED=true
      - CACHE_TTL_HOURS=24
      - CACHE_NAMESPACE_VERSION=\${CACHE_NAMESPACE_VERSION}
      - PLANNER_VERSION=\${PLANNER_VERSION}
      - NORMALIZER_VERSION=\${NORMALIZER_VERSION}
      - ASSEMBLER_VERSION=\${ASSEMBLER_VERSION}
      - LOG_LEVEL=INFO
    cpus: "${ROUTER_CPUS}"
    mem_limit: "${ROUTER_MEM_LIMIT}"
    networks: [tts-internal, proxy-network]
    depends_on:
      tts-api-ar:
        condition: service_healthy
      tts-api-en:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5073/health"]
      interval: 15s
      timeout: 5s
      retries: 3

  prometheus:
    image: prom/prometheus:latest
    container_name: tts-v4-prometheus
    restart: unless-stopped
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=7d"]
    volumes:
      - ${INSTALL_DIR}/data/prometheus:/prometheus
      - ${INSTALL_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    cpus: "0.5"
    mem_limit: "512m"
    ports: ["127.0.0.1:9099:9090"]
    networks: [tts-internal]

networks:
  tts-internal:
    driver: bridge
  proxy-network:
    external: true
COMPOSEEOF

ok "Wrote docker-compose.yml with fixed resource contract (no dynamic sizing)"

cat > "$INSTALL_DIR/prometheus.yml" <<'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: tts-router
    static_configs: [{targets: ["tts-router:5073"]}]
    metrics_path: /metrics

  - job_name: tts-arabic
    static_configs: [{targets: ["tts-api-ar:5072"]}]
    metrics_path: /metrics

  - job_name: tts-multilingual
    static_configs: [{targets: ["tts-api-en:5070"]}]
    metrics_path: /metrics
PROMEOF

ok "Wrote prometheus.yml"

# ------------------------------------------------------------------------------
# STEP 16 — Benchmark harness
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/scripts/benchmark_arabic.sh" <<'BENCHEOF'
#!/usr/bin/env bash
# Runs the 100/250/500/1000-char Arabic benchmark and logs chunk_count,
# duration, and manual quality flags to CSV.

set -euo pipefail

ROUTER="${1:-http://localhost:5073}"
API_KEY="${2:-}"

OUT_DIR="./benchmark-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT_DIR"

declare -A TEXTS=(
  [ar_100]="نص عربي قصير للاختبار يحتوي على مئة حرف تقريبًا للتحقق من جودة النطق الأساسية."
  [ar_250]="هذا نص عربي أطول قليلاً يستخدم لاختبار جودة النظام عند حدود مئتين وخمسين حرفًا، وهي النقطة التي كانت تظهر فيها مشاكل القطع في منتصف الكلمات سابقًا، ويجب أن يعالج هذا الإصدار هذه المشكلة تمامًا."
  [ar_500]="هذا نص عربي أطول بكثير مخصص لاختبار جودة النظام عند خمسمائة حرف تقريبًا. يحتوي هذا النص على عدة جمل متتالية مفصولة بعلامات ترقيم متنوعة؛ منها الفاصلة، والفاصلة المنقوطة، وعلامات الاستفهام؟ والغرض من ذلك هو التأكد من أن المقسم الجديد يتعامل مع جميع هذه الحالات بشكل صحيح دون أي قطع غير طبيعي في منتصف الكلمات أو الجمل."
  [ar_1000]="هذا نص عربي طويل جدًا مخصص لاختبار أداء النظام عند حدود الألف حرف تقريبًا. يتضمن هذا النص عدة فقرات وجمل مطولة ومتنوعة من حيث علامات الترقيم؛ حيث نجد الفاصلة، والفاصلة المنقوطة، والنقطتين، وعلامة الاستفهام؟ وعلامة التعجب! بالإضافة إلى ذلك، يحتوي النص على أرقام مثل ١٢٣ وأرقام أخرى مثل 456 للتحقق من تطبيع الأرقام العربية والهندية بشكل صحيح. الهدف الأساسي من هذا الاختبار هو التأكد من أن النظام الجديد يقسم النص إلى مقاطع طبيعية عند حدود الجمل والفقرات، وأنه يضيف وقفات مناسبة بين المقاطع، وأنه لا يقطع أي كلمة في منتصفها بغض النظر عن طول النص الإجمالي المرسل في طلب واحد."
)

echo "text_id,char_count,chunk_count,total_duration_s,cut_mid_word,audible_artifact,file_path" > "$OUT_DIR/results.csv"

for id in "${!TEXTS[@]}"; do
  text="${TEXTS[$id]}"
  char_count=${#text}
  out_file="$OUT_DIR/${id}.mp3"

  start=$(date +%s.%N)

  resp=$(curl -s -w "\n%{http_code}" -X POST "$ROUTER/v1/text-to-speech" \
    -H "Content-Type: application/json" \
    ${API_KEY:+-H "X-API-Key: $API_KEY"} \
    -d "{\"text\":\"$text\",\"language\":\"ar\",\"output_format\":\"mp3\"}" \
    -o "$out_file")

  end=$(date +%s.%N)

  duration=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.2f", e-s}')

  chunk_count="?"

  echo "$id,$char_count,$chunk_count,$duration,MANUAL_CHECK,MANUAL_CHECK,$out_file" >> "$OUT_DIR/results.csv"

  echo "[$id] chars=$char_count duration=${duration}s -> $out_file"
done

echo ""
echo "Benchmark files written to: $OUT_DIR"
echo "Fill in chunk_count from X-Chunks response header, and manually mark"
echo "cut_mid_word / audible_artifact after listening to each file."
BENCHEOF

chmod +x "$INSTALL_DIR/scripts/benchmark_arabic.sh"

ok "Wrote scripts/benchmark_arabic.sh"

# ------------------------------------------------------------------------------
# STEP 17 — Helper scripts
# ------------------------------------------------------------------------------

cat > "$INSTALL_DIR/scripts/health-check.sh" <<'HEOF'
#!/usr/bin/env bash

for entry in "Router:tts-v4-router:5073" "Arabic:tts-v4-api-ar:5072" "English:tts-v4-api-en:5070"; do
  IFS=: read -r label container port <<< "$entry"

  r=$(docker exec "$container" curl -sf "http://localhost:$port/health" 2>/dev/null || echo "unreachable")

  echo "$label: $r"
done

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "tts-v4|prometheus"
HEOF

chmod +x "$INSTALL_DIR/scripts/health-check.sh"

cat > "$INSTALL_DIR/scripts/cleanup.sh" <<'CEOF'
#!/usr/bin/env bash

cd /opt/tts-api-v4 && docker compose down

echo "Stopped. Use docker compose up -d to restart."
CEOF

chmod +x "$INSTALL_DIR/scripts/cleanup.sh"

ok "Wrote helper scripts"

# ------------------------------------------------------------------------------
# STEP 18 — Build and start
# ------------------------------------------------------------------------------

cd "$INSTALL_DIR"

set -a
source .env
source .env.resources
set +a

info "Building images (no-cache to ensure clean dependency resolution)..."
docker compose build --no-cache

info "Starting services..."
docker compose up -d tts-redis

info "Starting model engines; router will start only after both are healthy..."
docker compose up -d tts-api-ar tts-api-en

wait_for_health() {
  local container="$1"
  local max_seconds="$2"
  local elapsed=0

  while (( elapsed < max_seconds )); do
    if [[ "$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$container" 2>/dev/null || true)" == "healthy" ]]; then
      ok "$container is healthy"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  err "$container did not become healthy within ${max_seconds}s"
  docker logs "$container" --tail 100 || true

  return 1
}

wait_for_health tts-v4-api-ar 1800 || fatal "Arabic XTTS service failed readiness; router was not started."
wait_for_health tts-v4-api-en 180 || fatal "Kokoro service failed readiness; router was not started."

docker compose up -d tts-router prometheus

wait_for_health tts-v4-router 90 || fatal "Router failed readiness."

echo ""
echo -e "${BOLD}${GREEN}TTS API v${SCRIPT_VERSION} installation complete.${NC}"
echo ""
echo "Resource contract:"
echo "  Arabic XTTS:   ${AR_CPUS} vCPU / ${AR_MEM_LIMIT}  concurrent=${AR_CONCURRENT} threads=${AR_THREADS}"
echo "  Kokoro:        ${EN_CPUS} vCPU / ${EN_MEM_LIMIT}  concurrent=${EN_CONCURRENT}"
echo "  Router/Redis:  ${ROUTER_CPUS} vCPU shared"
echo ""
echo "REQUIRED before production cutover:"
echo "  1. Export n8n workflows to workflows.json"
echo "  2. python3 $INSTALL_DIR/scripts/audit_tts_languages.py"
echo "  3. Update $INSTALL_DIR/app/shared/supported_languages.yaml from audit results"
echo "  4. Rebuild router: docker compose build tts-router && docker compose up -d tts-router"
echo "  5. Run: $INSTALL_DIR/scripts/benchmark_arabic.sh http://localhost:5073 \$API_SECRET_KEY"
echo "  6. Compare chunk_count / cut_mid_word / audible_artifact against v3 baseline"
echo ""
echo "API Key:   ${APP_SECRET_KEY}"
echo "Admin Key: ${ADMIN_API_KEY}"
echo "Stored in: $INSTALL_DIR/.env"
echo ""
echo "Setup log: $LOG_FILE"