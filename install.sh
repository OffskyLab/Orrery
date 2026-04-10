#!/bin/bash
set -e

REPO="OffskyLab/Orbital"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="orbital"
BUILD_FROM_SOURCE=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --main) BUILD_FROM_SOURCE=true ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}Warning:${NC} $1"; }
error()   { echo -e "${RED}Error:${NC} $1"; exit 1; }

echo ""
echo "  Orbital — AI CLI environment manager"
echo ""

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *)      error "Unsupported OS: $OS" ;;
esac

# Detect arch
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) arch="arm64" ;;
  x86_64)        arch="x86_64" ;;
  *)             error "Unsupported architecture: $ARCH" ;;
esac

info "Detected: ${OS} ${ARCH}"

# Check install dir is writable
USE_SUDO=""
if [[ ! -w "$INSTALL_DIR" ]]; then
  warn "$INSTALL_DIR is not writable. Will use sudo."
  USE_SUDO="sudo"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

build_from_source() {
  if ! command -v swift &>/dev/null; then
    error "Swift not found. Install Swift to build from source:\n  https://www.swift.org/install/"
  fi

  info "Building from source (main branch)..."
  git clone --depth 1 "https://github.com/${REPO}.git" "$TMP_DIR/orbital" --quiet
  cd "$TMP_DIR/orbital"
  swift build -c release --quiet 2>&1

  BUILT_BINARY="$TMP_DIR/orbital/.build/release/$BINARY_NAME"
  if [[ ! -f "$BUILT_BINARY" ]]; then
    error "Build failed — binary not found."
  fi

  $USE_SUDO cp "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME"
  $USE_SUDO chmod +x "$INSTALL_DIR/$BINARY_NAME"
  info "Installed from source to $INSTALL_DIR/$BINARY_NAME"
}

if [[ "$BUILD_FROM_SOURCE" == "true" ]]; then
  build_from_source
else
  ASSET_NAME="orbital-${os}-${arch}.tar.gz"
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET_NAME}"

  info "Downloading pre-built binary..."
  if curl -fsSL -o "$TMP_DIR/$ASSET_NAME" "$DOWNLOAD_URL" 2>/dev/null; then
    tar -xzf "$TMP_DIR/$ASSET_NAME" -C "$TMP_DIR"
    $USE_SUDO cp "$TMP_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
    $USE_SUDO chmod +x "$INSTALL_DIR/$BINARY_NAME"
    info "Installed pre-built binary to $INSTALL_DIR/$BINARY_NAME"
  else
    warn "Pre-built binary not available for ${os}-${arch}."
    build_from_source
  fi
fi

# Verify
if ! command -v orbital &>/dev/null; then
  warn "orbital installed to $INSTALL_DIR but it's not in your PATH."
  warn "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
fi

VERSION=$(orbital --version 2>/dev/null || echo "installed")

# Fire-and-forget install ping (anonymous, no personal data)
curl -fsS "https://orbital-stats.REPLACE_WITH_YOUR_SUBDOMAIN.workers.dev/ping?os=${os}&arch=${arch}" \
  --max-time 3 --silent --output /dev/null &

echo ""
info "Orbital ${VERSION} successfully!"
echo ""
echo "  Next step — activate shell integration:"
echo ""
echo "    orbital setup && source ~/.orbital/activate.sh"
echo ""
