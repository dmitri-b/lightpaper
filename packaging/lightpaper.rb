# Homebrew cask template for the Lightpaper screen saver.
#
# This is a reference copy. The published copy lives in the tap repo
# `dmitri-b/homebrew-tap` at `Casks/lightpaper.rb`.
# For each release, bump `version` and set `sha256` to the checksum of the
# release's Lightpaper.saver.zip:
#
#   shasum -a 256 Lightpaper.saver.zip
#
# Install with:
#   brew install --cask dmitri-b/tap/lightpaper

cask "lightpaper" do
  version "0.1.8"
  sha256 "a8e91646fff4412d4a0d014f3f6251923502d4c2c9d3709792347cab50764e71"

  url "https://github.com/dmitri-b/lightpaper/releases/download/v#{version}/Lightpaper.saver.zip"
  name "Lightpaper"
  desc "Lightroom cache mosaic macOS screen saver"
  homepage "https://github.com/dmitri-b/lightpaper"

  depends_on macos: :sonoma

  screen_saver "Lightpaper.saver"

  # macOS caches the loaded screen saver bundle, so after an in-place upgrade
  # the old version keeps activating on idle until these agents are bounced.
  # Both relaunch on demand, so killing them is harmless.
  postflight do
    system_command "/usr/bin/killall", args: ["legacyScreenSaver"], sudo: false
    system_command "/usr/bin/killall", args: ["WallpaperAgent"],    sudo: false
  end

  caveats <<~EOS
    Lightpaper is not notarized. If macOS blocks it, clear the quarantine flag:
      xattr -dr com.apple.quarantine "~/Library/Screen Savers/Lightpaper.saver"

    Then choose Lightpaper in System Settings > Screen Saver.

    If a previously-running version still appears on idle after upgrading,
    log out and back in (or reboot) to force macOS to reload the bundle.
  EOS
end
