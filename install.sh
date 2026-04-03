#!/usr/bin/env bash
#
# install.sh — Build and install whisper-dictation from source.
#
# Prerequisites: Xcode Command Line Tools, git, cmake
# Usage: ./install.sh [--with-llm]
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────

INSTALL_DIR="$HOME/.local/share/whisper-dictation"
CONFIG_DIR="$HOME/.config/whisper-dictation"
BIN_DIR="$HOME/.local/bin"
WHISPER_MODEL="${WHISPER_MODEL:-medium}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WITH_LLM=false
if [[ "${1:-}" == "--with-llm" ]]; then
    WITH_LLM=true
fi

# ── Colors ────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; exit 1; }

# ── Preflight checks ─────────────────────────────────────────

info "Checking prerequisites..."

command -v git    >/dev/null || fail "git not found. Install Xcode Command Line Tools: xcode-select --install"
command -v cmake  >/dev/null || fail "cmake not found. Install via: brew install cmake"
command -v swift  >/dev/null || fail "swift not found. Install Xcode Command Line Tools: xcode-select --install"

ok "Prerequisites satisfied"

# ── Create directories ────────────────────────────────────────

mkdir -p "${INSTALL_DIR}/models"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${BIN_DIR}"

# ── Build whisper.cpp ─────────────────────────────────────────

WHISPER_DIR="${INSTALL_DIR}/whisper.cpp"

if [[ -d "${WHISPER_DIR}" ]]; then
    info "Updating whisper.cpp..."
    cd "${WHISPER_DIR}"
    git pull --quiet
else
    info "Cloning whisper.cpp..."
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "${WHISPER_DIR}"
    cd "${WHISPER_DIR}"
fi

info "Building whisper.cpp (with Metal/CoreML acceleration)..."
cmake -B build \
    -DWHISPER_METAL=ON \
    -DWHISPER_COREML=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}/whisper-install" \
    2>&1 | tail -5

cmake --build build --config Release -j "$(sysctl -n hw.ncpu)" 2>&1 | tail -5
cmake --install build 2>&1 | tail -5

ok "whisper.cpp built"

# ── Download Whisper model ────────────────────────────────────

MODEL_FILE="${INSTALL_DIR}/models/ggml-${WHISPER_MODEL}.bin"

if [[ -f "${MODEL_FILE}" ]]; then
    ok "Whisper model already downloaded: ${WHISPER_MODEL}"
else
    info "Downloading Whisper model: ${WHISPER_MODEL} ..."
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin"
    curl -L --progress-bar -o "${MODEL_FILE}" "${MODEL_URL}"
    ok "Model downloaded: $(du -h "${MODEL_FILE}" | cut -f1)"
fi

# ── (Optional) Build llama.cpp + download LLM model ──────────

if $WITH_LLM; then
    LLAMA_DIR="${INSTALL_DIR}/llama.cpp"

    if [[ -d "${LLAMA_DIR}" ]]; then
        info "Updating llama.cpp..."
        cd "${LLAMA_DIR}"
        git pull --quiet
    else
        info "Cloning llama.cpp..."
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
        cd "${LLAMA_DIR}"
    fi

    info "Building llama.cpp..."
    cmake -B build \
        -DLLAMA_METAL=ON \
        -DCMAKE_BUILD_TYPE=Release \
        2>&1 | tail -5
    cmake --build build --config Release -j "$(sysctl -n hw.ncpu)" 2>&1 | tail -5

    ok "llama.cpp built"

    LLM_MODEL="${INSTALL_DIR}/models/ggml-smollm2-1.7b-q4_k_m.gguf"
    if [[ ! -f "${LLM_MODEL}" ]]; then
        info "Downloading SmolLM2 1.7B (Q4_K_M, ~1GB)..."
        curl -L --progress-bar -o "${LLM_MODEL}" \
            "https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf"
        ok "LLM model downloaded: $(du -h "${LLM_MODEL}" | cut -f1)"
    else
        ok "LLM model already downloaded"
    fi
fi

# ── Build whisper-dictation Swift binary ──────────────────────

cd "${SCRIPT_DIR}"

# Set up the C header path so Swift can find whisper.h
WHISPER_INCLUDE="${INSTALL_DIR}/whisper-install/include"
WHISPER_LIB="${INSTALL_DIR}/whisper-install/lib"

# Copy whisper.h into our CWhisper module so Swift can find it
cp "${WHISPER_INCLUDE}/whisper.h" "Sources/CWhisper/whisper.h"

info "Building whisper-dictation..."

swift build -c release \
    -Xcc "-I${WHISPER_INCLUDE}" \
    -Xlinker "-L${WHISPER_LIB}" \
    -Xlinker "-lwhisper" \
    -Xlinker "-rpath" -Xlinker "${WHISPER_LIB}" \
    2>&1 | tail -5

# Copy binary
cp "$(swift build -c release --show-bin-path)/WhisperDictation" "${BIN_DIR}/whisper-dictation"
ok "Binary installed to ${BIN_DIR}/whisper-dictation"

# ── Write default config if none exists ───────────────────────

CONFIG_FILE="${CONFIG_DIR}/config.json"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    LLM_ENABLED="false"
    if $WITH_LLM; then
        LLM_ENABLED="true"
    fi

    cat > "${CONFIG_FILE}" <<CONF
{
  "doubleTapInterval": 0.4,
  "enableLLMCleanup": ${LLM_ENABLED},
  "language": "auto",
  "llmCleanupModel": "ggml-smollm2-1.7b-q4_k_m.gguf",
  "maxRecordSeconds": 120,
  "model": "${WHISPER_MODEL}",
  "notifySound": true,
  "silenceTimeout": 2.0,
  "threads": 0
}
CONF
    ok "Default config written to ${CONFIG_FILE}"
fi

# ── Install launchd agent ─────────────────────────────────────

PLIST_NAME="com.whisper-dictation.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/whisper-dictation</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DYLD_LIBRARY_PATH</key>
        <string>${WHISPER_LIB}</string>
    </dict>
</dict>
</plist>
PLIST

# Load the agent
launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

ok "launchd agent installed and started"

# ── Done ──────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━ Installation complete ━━━${NC}"
echo ""
echo "  Binary:  ${BIN_DIR}/whisper-dictation"
echo "  Config:  ${CONFIG_FILE}"
echo "  Model:   ${MODEL_FILE}"
echo "  Logs:    ${INSTALL_DIR}/stdout.log"
echo ""
echo "  Double-tap Control to start/stop dictation."
echo ""
echo -e "${YELLOW}Important:${NC} Grant Accessibility permission:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  Add: ${BIN_DIR}/whisper-dictation"
echo ""
if ! $WITH_LLM; then
    echo "  To enable LLM text cleanup, re-run: ./install.sh --with-llm"
fi
