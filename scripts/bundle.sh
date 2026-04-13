#!/bin/bash
set -euo pipefail

# Assemble op-who.app from SPM build output.
#
# Usage:
#   scripts/bundle.sh              # debug build
#   scripts/bundle.sh release      # release build

CONFIG="${1:-debug}"
PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"

cd "$(dirname "$0")/.."

# Build
echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BUILD_DIR=".build/${CONFIG}"
APP_DIR=".build/${APP_NAME}"

# Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BUILD_DIR/$PRODUCT" "$APP_DIR/Contents/MacOS/"
cp Sources/OpWhoLib/Info.plist "$APP_DIR/Contents/"

echo "Bundle assembled: $APP_DIR"
