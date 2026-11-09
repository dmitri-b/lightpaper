#!/bin/sh
# Scores the screen saver's mosaic against the chosen look: justified rows, no
# gaps, full-bleed (no black anywhere), even rows, ~10 photos, minimal crop and
# enlargement. Runs the real saver source (LightpaperScreenSaverView.presentGallery)
# offscreen on 32 fixture screens (real preview dimensions) x 6 displays.
# Set LAYOUT_PREVIEWS=dir to also dump per-screen layout PNGs.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT_DIR/.build/bench"
mkdir -p "$OUT"

# One compilation unit so the bench can reach the saver's file-private types.
cat "$ROOT_DIR/Sources/LightpaperScreenSaver/LightpaperScreenSaver.swift" \
    "$ROOT_DIR/bench/LayoutBench.swift" > "$OUT/combined.swift"

swiftc \
    -parse-as-library \
    -O \
    -module-cache-path "$OUT/ModuleCache" \
    -module-name LightpaperBench \
    -o "$OUT/layout-bench" \
    -framework AppKit \
    -framework ImageIO \
    -framework ScreenSaver \
    -framework Vision \
    "$OUT/combined.swift" 2>&1 | grep -E "error" && exit 1

"$OUT/layout-bench" "$ROOT_DIR/bench/fixture.json" ${LAYOUT_PREVIEWS:-}
