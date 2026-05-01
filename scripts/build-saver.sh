#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
SAVER_NAME=${SAVER_NAME:-Lightpaper}
PRODUCT_NAME=LightpaperScreenSaver

BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
SAVER_DIR="$ROOT_DIR/.build/$SAVER_NAME.saver"
CONTENTS_DIR="$SAVER_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$SAVER_DIR"
mkdir -p "$MACOS_DIR" "$BUILD_DIR"

swiftc \
    -parse-as-library \
    -O \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -module-name "$PRODUCT_NAME" \
    -emit-library \
    -o "$MACOS_DIR/$PRODUCT_NAME" \
    -framework AppKit \
    -framework ImageIO \
    -framework ScreenSaver \
    "$ROOT_DIR/Sources/LightpaperScreenSaver/LightpaperScreenSaver.swift"

cp "$ROOT_DIR/Resources/Lightpaper.saver/Contents/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$SAVER_DIR" >/dev/null
fi

printf 'Built %s\n' "$SAVER_DIR"
