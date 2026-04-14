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

info "Building whisper.cpp (with Metal acceleration)..."
cmake -B build \
    -DWHISPER_METAL=ON \
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

info "Building Escriba..."

swift build -c release \
    -Xcc "-I${WHISPER_INCLUDE}" \
    -Xlinker "-L${WHISPER_LIB}" \
    -Xlinker "-lwhisper" \
    -Xlinker "-rpath" -Xlinker "@executable_path" \
    2>&1 | tail -5

# ── Create .app bundle inside ~/.local/share ──────────────────
# The bundle lives in ~/.local/share/escriba/ so Santa's home-directory
# scope rule allows it (Santa blocks unknown binaries in /Applications/).
# Running from inside a bundle gives TCC a stable bundle-ID identity
# (com.whisper-dictation.escriba) instead of a per-rebuild binary hash,
# so the Accessibility grant survives future rebuilds.

APP_DIR="${HOME}/.local/share/escriba/Escriba.app"
APP_CONTENTS="${APP_DIR}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"

info "Installing Escriba.app bundle..."
mkdir -p "${APP_MACOS}"

# Copy the unsigned binary into the bundle first
cp "$(swift build -c release --show-bin-path)/WhisperDictation" "${APP_MACOS}/Escriba"

# Co-locate all ggml/whisper dylibs next to the binary
for lib in $(find "${WHISPER_LIB}" -name '*.dylib' | grep -v coreml); do
    cp "${lib}" "${APP_MACOS}/"
done
# Ensure .0.dylib symlinks exist
for versioned in "${APP_MACOS}"/lib*.*.*.dylib; do
    base=$(basename "$versioned")
    short=$(echo "$base" | sed 's/\.[0-9]*\.[0-9]*\.dylib/.dylib/')
    dot0=$(echo "$base"  | sed 's/\.[0-9]*\.[0-9]*\.dylib/.0.dylib/')
    [[ -f "${APP_MACOS}/$short" ]] || ln -sf "$base" "${APP_MACOS}/$short"
    [[ -f "${APP_MACOS}/$dot0"  ]] || ln -sf "$base" "${APP_MACOS}/$dot0"
done

ok "Binary + dylibs installed inside ${APP_DIR}"

# Convenience symlink in PATH
ln -sf "${APP_MACOS}/Escriba" "${BIN_DIR}/escriba"

# Info.plist
cat > "${APP_CONTENTS}/Info.plist" <<'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Escriba</string>
    <key>CFBundleIdentifier</key>
    <string>com.whisper-dictation.escriba</string>
    <key>CFBundleName</key>
    <string>Escriba</string>
    <key>CFBundleDisplayName</key>
    <string>Escriba</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Escriba needs microphone access to transcribe your speech.</string>
</dict>
</plist>
INFOPLIST

# Sign the entire bundle after all files are in place.
# Signing the binary before copying into the bundle produces an invalid
# signature ("code has no resources but signature indicates they must be
# present"), which causes OS_REASON_CODESIGNING crashes at launch.
codesign --force --sign - \
    --identifier com.whisper-dictation.escriba \
    "${APP_DIR}"

ok "Escriba.app signed and installed at ${APP_DIR}"

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
        <string>${APP_MACOS}/Escriba</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/stderr.log</string>
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
echo "  App:     /Applications/Escriba.app"
echo "  Binary:  ${BIN_DIR}/whisper-dictation"
echo "  Config:  ${CONFIG_FILE}"
echo "  Model:   ${MODEL_FILE}"
echo "  Logs:    ${INSTALL_DIR}/stdout.log"
echo ""
echo "  Double-tap Control to start/stop dictation."
echo ""
echo -e "${YELLOW}Important:${NC} Grant Accessibility permission:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  Add: /Applications/Escriba.app (or ${BIN_DIR}/whisper-dictation)"
echo ""
if ! $WITH_LLM; then
    echo "  To enable LLM text cleanup, re-run: ./install.sh --with-llm"
fi
