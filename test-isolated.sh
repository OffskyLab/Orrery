#!/bin/bash
# Isolated test runner for Orrery development
# This prevents tests from touching the real ~/.claude and ~/.orrery directories

set -e

# Use a temporary directory for ORRERY_HOME
export ORRERY_HOME="/tmp/orrery-dev-test-$(date +%s)"
export ORRERY_SKIP_UPDATE_CHECK=1

echo "========================================="
echo "Orrery Isolated Test Environment"
echo "========================================="
echo "ORRERY_HOME: $ORRERY_HOME"
echo "Real ~/.orrery will NOT be touched"
echo ""

# Create the test home directory
mkdir -p "$ORRERY_HOME"

# Run tests
echo "Running: swift test $@"
echo ""
swift test "$@"

# Cleanup
echo ""
echo "Cleaning up test environment..."
rm -rf "$ORRERY_HOME"
echo "Done!"
