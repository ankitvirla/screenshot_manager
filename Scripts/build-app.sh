#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/Screenshot Manager.app"

cd "$ROOT_DIR"
swift build -c release
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp .build/release/ScreenshotManager "$APP_BUNDLE/Contents/MacOS/ScreenshotManager"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
printf 'Built %s\n' "$APP_BUNDLE"