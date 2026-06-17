# Lightpaper

Photographers have tens or hundreds of thousands of images sitting unused in
Lightroom. Lightpaper turns the local Lightroom cache into a macOS wallpaper /
screen saver, so those photos keep resurfacing for you, your family, and friends.

Lightpaper only reads local cached Lightroom Desktop files. It does not contact
Adobe, sign in to your account, or communicate with remote Adobe storage.

## Install

No toolchain required — both options install a prebuilt universal `.saver` from
the latest [GitHub release](https://github.com/dmitri-b/lightpaper/releases).

Homebrew (recommended):

```sh
brew install --cask dmitri-b/tap/lightpaper
```

Or a one-line script:

```sh
curl -fsSL https://raw.githubusercontent.com/dmitri-b/lightpaper/master/scripts/install.sh | sh
```

Enable it:

1. Open System Settings.
2. Go to Screen Saver.
3. Pick Lightpaper.

Lightpaper is not notarized. If macOS blocks it, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine "$HOME/Library/Screen Savers/Lightpaper.saver"
```

### Build from source

```sh
gh repo clone dmitri-b/lightpaper
cd lightpaper
./scripts/install-saver.sh
```

## Screenshots

Final wallpaper:

![Final Lightpaper wallpaper screenshot](docs/screenshots/final-wallpaper.png)

macOS Screen Saver setting:

![Lightpaper selected in macOS Screen Saver settings](docs/screenshots/macos-screen-saver-settings-123.png)

## Debug

Build and open the app bundle:

```sh
./scripts/build-app.sh
open .build/Lightpaper.app
```

Run windowed:

```sh
swift run lightpaper-view -- --windowed --mode mosaic --limit 500
swift run lightpaper-view -- --windowed --mode slideshow --source previews
```

Scan the Lightroom cache:

```sh
swift run lightpaper-scan -- --source previews --limit 10
swift run lightpaper-scan -- --json
```

Keys:

- `Space`, `Right`, `Down`, `L`: next
- `Left`, `Up`, `J`: previous
- `Esc`, `Q`: quit

Requires a local Lightroom Desktop library at `~/Pictures/Lightroom Library.lrlibrary`.
