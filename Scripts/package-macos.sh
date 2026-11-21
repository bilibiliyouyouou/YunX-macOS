#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/macos-build/YunX.app"
BUILD_DIR="$ROOT_DIR/.build/release"
mkdir -p "$BUILD_DIR"

swiftc -swift-version 5 -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -o "$BUILD_DIR/YunXMac" \
    "$ROOT_DIR/Sources/YunXMac/DownloadJob.swift" \
    "$ROOT_DIR/Sources/YunXMac/LinkClassifier.swift" \
    "$ROOT_DIR/Sources/YunXMac/DownloadManager.swift" \
    "$ROOT_DIR/Sources/YunXMac/ContentView.swift" \
    "$ROOT_DIR/Sources/YunXMac/YunXMacApp.swift"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/YunXMac" "$APP_DIR/Contents/MacOS/YunXMac"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

printf 'Created app bundle: %s\n' "$APP_DIR"
printf 'Open it with: open "%s"\n' "$APP_DIR"
