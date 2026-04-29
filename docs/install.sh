#!/bin/bash
set -e

REPO="OffskyLab/Orrery"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="orrery-bin"
OLD_BINARY_NAME="orrery"   # legacy name (< 2.4); removed on install
BUILD_FROM_SOURCE=false

# orrery-magi sidecar — required runtime dependency for `orrery magi`.
# Installed under ~/.orrery/bin/ (user-scope, no sudo) where the orrery
# shim looks for it second-priority after $ORRERY_MAGI_PATH.
MAGI_REPO="OffskyLab/orrery-magi"
MAGI_BINARY="orrery-magi"
MAGI_DIR="$HOME/.orrery/bin"

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
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}Warning:${NC} $1"; }
error()   { echo -e "${RED}Error:${NC} $1"; exit 1; }

echo ""
echo "  Orrery — AI CLI environment manager"
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
  git clone --depth 1 "https://github.com/${REPO}.git" "$TMP_DIR/orrery" --quiet
  cd "$TMP_DIR/orrery"
  swift build -c release --quiet 2>&1

  BUILT_BINARY="$TMP_DIR/orrery/.build/release/$BINARY_NAME"
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
  ASSET_NAME="orrery-${os}-${arch}.tar.gz"
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET_NAME}"

  info "Downloading pre-built binary..."
  if curl -fsSL -o "$TMP_DIR/$ASSET_NAME" "$DOWNLOAD_URL" 2>/dev/null; then
    tar -xzf "$TMP_DIR/$ASSET_NAME" -C "$TMP_DIR"
    # Tarball may contain either `orrery-bin` (>= 2.4) or the legacy `orrery`
    # (<= 2.3.x). Normalize to orrery-bin on disk so downstream always uses
    # the new name.
    if [[ -f "$TMP_DIR/$BINARY_NAME" ]]; then
      EXTRACTED="$TMP_DIR/$BINARY_NAME"
    elif [[ -f "$TMP_DIR/$OLD_BINARY_NAME" ]]; then
      EXTRACTED="$TMP_DIR/$OLD_BINARY_NAME"
    else
      error "Tarball contents unexpected — no binary found."
    fi
    $USE_SUDO cp "$EXTRACTED" "$INSTALL_DIR/$BINARY_NAME"
    $USE_SUDO chmod +x "$INSTALL_DIR/$BINARY_NAME"
    if [[ -d "$TMP_DIR/orrery_OrreryThirdParty.bundle" ]]; then
      $USE_SUDO cp -r "$TMP_DIR/orrery_OrreryThirdParty.bundle" "$INSTALL_DIR/"
    elif [[ -d "$TMP_DIR/orrery_OrreryThirdParty.resources" ]]; then
      $USE_SUDO cp -r "$TMP_DIR/orrery_OrreryThirdParty.resources" "$INSTALL_DIR/"
    fi
    info "Installed pre-built binary to $INSTALL_DIR/$BINARY_NAME"
  else
    warn "Pre-built binary not available for ${os}-${arch}."
    build_from_source
  fi
fi

# Remove the legacy binary so users can't bypass the shell function.
if [[ -e "$INSTALL_DIR/$OLD_BINARY_NAME" ]]; then
  info "Removing legacy binary at $INSTALL_DIR/$OLD_BINARY_NAME (users now go through the shell function)."
  $USE_SUDO rm -f "$INSTALL_DIR/$OLD_BINARY_NAME"
fi

# Install orrery-magi sidecar (required runtime dependency).
install_magi_from_source() {
  if ! command -v swift &>/dev/null; then
    warn "Swift not found — orrery-magi not installed. \`orrery magi\` will hard-fail."
    return 1
  fi
  info "Building orrery-magi from source (main branch)..."
  git clone --depth 1 "https://github.com/${MAGI_REPO}.git" "$TMP_DIR/orrery-magi" --quiet
  ( cd "$TMP_DIR/orrery-magi" && swift build -c release --quiet 2>&1 )
  local built="$TMP_DIR/orrery-magi/.build/release/$MAGI_BINARY"
  if [[ ! -f "$built" ]]; then
    warn "orrery-magi build failed — \`orrery magi\` will hard-fail."
    return 1
  fi
  mkdir -p "$MAGI_DIR"
  cp "$built" "$MAGI_DIR/$MAGI_BINARY"
  chmod +x "$MAGI_DIR/$MAGI_BINARY"
  info "Built orrery-magi from source to $MAGI_DIR/$MAGI_BINARY"
}

install_magi() {
  if [[ "$BUILD_FROM_SOURCE" == "true" ]]; then
    install_magi_from_source
    return
  fi
  local asset="orrery-magi-${os}-${arch}.tar.gz"
  local url="https://github.com/${MAGI_REPO}/releases/latest/download/${asset}"
  info "Downloading orrery-magi pre-built binary..."
  if ! curl -fsSL -o "$TMP_DIR/$asset" "$url" 2>/dev/null; then
    warn "orrery-magi pre-built binary not available for ${os}-${arch} — falling back to source build."
    install_magi_from_source
    return
  fi
  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR"
  if [[ ! -f "$TMP_DIR/$MAGI_BINARY" ]]; then
    warn "orrery-magi tarball missing binary — falling back to source build."
    install_magi_from_source
    return
  fi
  mkdir -p "$MAGI_DIR"
  cp "$TMP_DIR/$MAGI_BINARY" "$MAGI_DIR/$MAGI_BINARY"
  chmod +x "$MAGI_DIR/$MAGI_BINARY"
  info "Installed orrery-magi to $MAGI_DIR/$MAGI_BINARY"
}

install_magi

# Verify
if ! command -v "$BINARY_NAME" &>/dev/null; then
  warn "$BINARY_NAME installed to $INSTALL_DIR but it's not in your PATH."
  warn "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
fi

VERSION=$($BINARY_NAME --version 2>/dev/null || echo "installed")

echo ""
info "Orrery ${VERSION} installed."
echo ""

# Auto-run setup — generates activate.sh, patches rc file with the
# lazy-bootstrap stub, and performs origin takeover. Setup skips interactive
# prompts when /dev/tty is unavailable, so it's safe under `curl | bash`.
if command -v "$BINARY_NAME" &>/dev/null; then
  info "Running orrery setup..."
  echo ""
  "$BINARY_NAME" setup || warn "orrery setup exited with a non-zero status — run it manually later."
fi

echo ""
echo -e "${CYAN}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}  Next step — activate in this shell:${NC}"
echo ""
echo -e "    ${GREEN}source ~/.orrery/activate.sh${NC}"
echo ""
echo -e "${CYAN}──────────────────────────────────────────────${NC}"
echo "  New shells pick it up automatically via your rc file."
echo ""
