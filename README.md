# Lightpaper

Personal fullscreen macOS app tooling for reading locally cached Lightroom desktop photos.

## Install screen saver from GitHub

```sh
gh repo clone dmitri-b/lightpaper && lightpaper/scripts/install-saver.sh
```

Then choose Lightpaper in System Settings > Screen Saver.

Build the app bundle:

```sh
./scripts/build-app.sh
open .build/Lightpaper.app
```

By default, Lightpaper opens fullscreen, hides the cursor, and auto-hides the
menu bar and Dock. Pass `--windowed` when running the viewer directly if you want
a resizable debug window.

The first slice is a read-only scanner:

```sh
swift run lightpaper-scan -- --source previews --limit 10
swift run lightpaper-scan -- --json
```

It discovers `~/Pictures/Lightroom Library.lrlibrary`, scans local `previews/` and
`originals/` folders, validates image files by magic bytes, and reports a small
manifest. It does not modify Adobe files.

The second slice is a simple Lightroom cache slideshow viewer:

```sh
swift run lightpaper-view -- --mode mosaic --windowed --limit 500
swift run lightpaper-view -- --mode slideshow --source previews
swift run lightpaper-view -- --windowed --limit 50 --quit-after 5
```

Keys:

- Space / Right Arrow / Down Arrow / L: next screen or photo
- Left Arrow / Up Arrow / J: previous screen or photo
- Esc / Q: quit
