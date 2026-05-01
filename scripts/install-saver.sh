#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SAVER_NAME=${SAVER_NAME:-Lightpaper}
SOURCE_DIR="$ROOT_DIR/.build/$SAVER_NAME.saver"
DESTINATION_DIR="${DESTINATION_DIR:-$HOME/Library/Screen Savers}"

if [ ! -d "$SOURCE_DIR" ]; then
    "$ROOT_DIR/scripts/build-saver.sh"
fi

mkdir -p "$DESTINATION_DIR"
rm -rf "$DESTINATION_DIR/$SAVER_NAME.saver"
cp -R "$SOURCE_DIR" "$DESTINATION_DIR/$SAVER_NAME.saver"

printf 'Installed %s\n' "$DESTINATION_DIR/$SAVER_NAME.saver"
