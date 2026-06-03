#!/bin/bash
# Quick test for specific test suites
set -e

export ORRERY_HOME="/tmp/orrery-dev-test-$(date +%s)"
export ORRERY_SKIP_UPDATE_CHECK=1

mkdir -p "$ORRERY_HOME"
swift test --filter "$1"
rm -rf "$ORRERY_HOME"
