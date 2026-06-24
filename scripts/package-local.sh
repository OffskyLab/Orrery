#!/bin/bash
set -e

# Package Orrery for local testing/distribution
# Usage: ./scripts/package-local.sh [output-dir]

OUTPUT_DIR="${1:-.}"
BINARY_NAME="orrery-bin"
VERSION=$(grep 'public static let current' Sources/OrreryCore/Version.swift | sed 's/.*"\(.*\)".*/\1/')

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}Warning:${NC} $1"; }

echo ""
echo "  Orrery Local Package Builder"
echo "  Version: ${VERSION}"
echo ""

# Detect OS and arch
OS="$(uname -s)"
case "$OS" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) arch="arm64" ;;
  x86_64)        arch="x86_64" ;;
  *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

info "Building for: ${os}-${arch}"

# Build release binary
info "Building release binary..."
swift build -c release

# Check if binary exists
BUILT_BINARY=".build/release/${BINARY_NAME}"
if [[ ! -f "$BUILT_BINARY" ]]; then
  echo "Error: Build failed — binary not found at $BUILT_BINARY"
  exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Package tarball
TARBALL_NAME="orrery-${os}-${arch}-${VERSION}-local.tar.gz"
# Convert to absolute path
if [[ "$OUTPUT_DIR" = /* ]]; then
  TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"
else
  TARBALL_PATH="$(pwd)/${OUTPUT_DIR}/${TARBALL_NAME}"
fi

info "Creating tarball: ${TARBALL_NAME}"

# Create temporary staging directory
TMP_STAGE=$(mktemp -d)
trap 'rm -rf "$TMP_STAGE"' EXIT

# Copy binary
cp "$BUILT_BINARY" "$TMP_STAGE/"

# Copy resources if they exist
if [[ -d ".build/release/orrery_OrreryThirdParty.bundle" ]]; then
  cp -r ".build/release/orrery_OrreryThirdParty.bundle" "$TMP_STAGE/"
elif [[ -d ".build/release/orrery_OrreryThirdParty.resources" ]]; then
  cp -r ".build/release/orrery_OrreryThirdParty.resources" "$TMP_STAGE/"
fi

# Create tarball (use absolute path to avoid issues with cleanup)
( cd "$TMP_STAGE" && tar -czf "$TARBALL_PATH" * )

# Get file size (before cleanup)
SIZE=$(du -h "$TARBALL_PATH" | awk '{print $1}')

echo ""
info "Package created successfully!"
echo ""
echo -e "${CYAN}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}  Package Details:${NC}"
echo ""
echo "  File:     ${TARBALL_NAME}"
echo "  Path:     ${TARBALL_PATH}"
echo "  Size:     ${SIZE}"
echo "  Version:  ${VERSION}"
echo "  Platform: ${os}-${arch}"
echo ""
echo -e "${CYAN}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}  Installation on target machine:${NC}"
echo ""
echo "  1. Copy this tarball to the target machine"
echo "  2. Run: tar -xzf ${TARBALL_NAME}"
echo "  3. Run: sudo cp orrery-bin /usr/local/bin/"
echo "  4. Run: sudo chmod +x /usr/local/bin/orrery-bin"
echo "  5. Run: orrery-bin setup"
echo ""
echo "  Or use the install-local.sh script:"
echo "  ./scripts/install-local.sh ${TARBALL_NAME}"
echo ""
echo -e "${CYAN}──────────────────────────────────────────────${NC}"
echo ""
