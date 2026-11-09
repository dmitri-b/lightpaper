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

# Build a universal binary so the released saver runs on both Apple Silicon and
# Intel Macs. swiftc emits one slice per arch; lipo stitches them together.
ARCHS=${ARCHS:-"arm64 x86_64"}
SLICES=""
for arch in $ARCHS; do
    slice="$BUILD_DIR/$PRODUCT_NAME-$arch"
    swiftc \
        -parse-as-library \
        -O \
        -target "$arch-apple-macos14" \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        -module-name "$PRODUCT_NAME" \
        -emit-library \
        -o "$slice" \
        -framework AppKit \
        -framework ImageIO \
        -framework ScreenSaver \
        -framework Vision \
        "$ROOT_DIR/Sources/LightpaperScreenSaver/LightpaperScreenSaver.swift"
    SLICES="$SLICES $slice"
done

# shellcheck disable=SC2086
lipo -create -output "$MACOS_DIR/$PRODUCT_NAME" $SLICES

cp "$ROOT_DIR/Resources/Lightpaper.saver/Contents/Info.plist" "$CONTENTS_DIR/Info.plist"

# Stamp when, and from which commit, this bundle was built so the indexing screen
# can show it — the version number alone doesn't change between local builds.
# "+dirty" marks a build with uncommitted changes.
PLIST="$CONTENTS_DIR/Info.plist"
BUILD_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if COMMIT=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null); then
    git -C "$ROOT_DIR" diff --quiet HEAD -- || COMMIT="$COMMIT+dirty"
else
    COMMIT=unknown
fi
/usr/libexec/PlistBuddy \
    -c "Add :LightpaperBuildDate string $BUILD_DATE" \
    -c "Add :LightpaperCommit string $COMMIT" \
    "$PLIST"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$SAVER_DIR" >/dev/null
fi

printf 'Built %s\n' "$SAVER_DIR"
