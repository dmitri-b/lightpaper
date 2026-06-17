#!/bin/sh
set -eu

# One-line installer for the Lightpaper screen saver. Downloads the prebuilt,
# universal .saver from the latest GitHub release and installs it for the
# current user. No Swift toolchain required.
#
#   curl -fsSL https://raw.githubusercontent.com/dmitri-b/lightpaper/master/scripts/install.sh | sh

REPO=${REPO:-dmitri-b/lightpaper}
SAVER_NAME=${SAVER_NAME:-Lightpaper}
ASSET="$SAVER_NAME.saver.zip"
DESTINATION_DIR="${DESTINATION_DIR:-$HOME/Library/Screen Savers}"

# Allow overriding with a local zip for testing: ASSET_URL=file:///path/to.zip
ASSET_URL=${ASSET_URL:-}
if [ -z "$ASSET_URL" ]; then
    api="https://api.github.com/repos/$REPO/releases/latest"
    ASSET_URL=$(curl -fsSL "$api" \
        | grep -o "https://[^\"]*/$ASSET" \
        | head -1)
fi

if [ -z "$ASSET_URL" ]; then
    printf 'Could not find %s in the latest release of %s\n' "$ASSET" "$REPO" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf 'Downloading %s\n' "$ASSET_URL"
case "$ASSET_URL" in
    file://*) cp "${ASSET_URL#file://}" "$TMP_DIR/$ASSET" ;;
    *) curl -fsSL "$ASSET_URL" -o "$TMP_DIR/$ASSET" ;;
esac

ditto -xk "$TMP_DIR/$ASSET" "$TMP_DIR/unpacked"

mkdir -p "$DESTINATION_DIR"
rm -rf "$DESTINATION_DIR/$SAVER_NAME.saver"
cp -R "$TMP_DIR/unpacked/$SAVER_NAME.saver" "$DESTINATION_DIR/$SAVER_NAME.saver"

# Lightpaper is not notarized, so the download carries a quarantine flag that
# Gatekeeper would otherwise block. Clearing it here (from a script the user
# ran themselves) lets the saver load without a manual right-click > Open.
xattr -dr com.apple.quarantine "$DESTINATION_DIR/$SAVER_NAME.saver" 2>/dev/null || true

printf 'Installed %s\n' "$DESTINATION_DIR/$SAVER_NAME.saver"
printf 'Choose %s in System Settings > Screen Saver.\n' "$SAVER_NAME"
