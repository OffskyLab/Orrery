#!/bin/bash
set -e

# Install Orrery from a local tarball
# Usage: ./scripts/install-local.sh <tarball-path>

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tarball-path>"
  echo ""
  echo "Example:"
  echo "  $0 orrery-darwin-arm64-3.1.0-rc.2-local.tar.gz"
  exit 1
fi

TARBALL="$1"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="orrery-bin"
OLD_BINARY_NAME="orrery"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}Warning:${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1"; exit 1; }

echo ""
echo "  Orrery — Local Installation"
echo ""

# Check tarball exists
if [[ ! -f "$TARBALL" ]]; then
  error "Tarball not found: $TARBALL"
fi

info "Installing from: $TARBALL"

# Check install dir is writable
USE_SUDO=""
if [[ ! -w "$INSTALL_DIR" ]]; then
  warn "$INSTALL_DIR is not writable. Will use sudo."
  USE_SUDO="sudo"
fi

# Create temp directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Extract tarball
info "Extracting tarball..."
tar -xzf "$TARBALL" -C "$TMP_DIR"

# Install binary
if [[ -f "$TMP_DIR/$BINARY_NAME" ]]; then
  EXTRACTED="$TMP_DIR/$BINARY_NAME"
elif [[ -f "$TMP_DIR/$OLD_BINARY_NAME" ]]; then
  EXTRACTED="$TMP_DIR/$OLD_BINARY_NAME"
else
  error "Binary not found in tarball."
fi

info "Installing binary to $INSTALL_DIR/$BINARY_NAME"
$USE_SUDO cp "$EXTRACTED" "$INSTALL_DIR/$BINARY_NAME"
$USE_SUDO chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Install resources if present
if [[ -d "$TMP_DIR/orrery_OrreryThirdParty.bundle" ]]; then
  info "Installing resource bundle..."
  $USE_SUDO cp -r "$TMP_DIR/orrery_OrreryThirdParty.bundle" "$INSTALL_DIR/"
elif [[ -d "$TMP_DIR/orrery_OrreryThirdParty.resources" ]]; then
  info "Installing resources..."
  $USE_SUDO cp -r "$TMP_DIR/orrery_OrreryThirdParty.resources" "$INSTALL_DIR/"
fi

# Remove legacy binary if exists
if [[ -e "$INSTALL_DIR/$OLD_BINARY_NAME" ]]; then
  info "Removing legacy binary at $INSTALL_DIR/$OLD_BINARY_NAME"
  $USE_SUDO rm -f "$INSTALL_DIR/$OLD_BINARY_NAME"
fi

# macOS Gatekeeper sanitization
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  info "Removing quarantine attributes (macOS)..."
  $USE_SUDO xattr -cr "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null || true
  $USE_SUDO codesign --force --sign - "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null || true
fi

# Verify installation
if ! command -v "$BINARY_NAME" &>/dev/null; then
  warn "$BINARY_NAME installed to $INSTALL_DIR but it's not in your PATH."
  warn "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
fi

VERSION=$($BINARY_NAME --version 2>/dev/null || echo "unknown")

echo ""
info "Orrery ${VERSION} installed successfully!"
echo ""

# Auto-run setup
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
