# Homebrew cask template for the Lightpaper screen saver.
#
# This is a reference copy. To publish, create a tap repo
# `dmitri-b/homebrew-lightpaper` and copy this file to its `Casks/lightpaper.rb`.
# For each release, bump `version` and set `sha256` to the checksum of the
# release's Lightpaper.saver.zip:
#
#   shasum -a 256 Lightpaper.saver.zip
#
# Install with:
#   brew install --cask dmitri-b/lightpaper/lightpaper

cask "lightpaper" do
  version "0.1.8"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/dmitri-b/lightpaper/releases/download/v#{version}/Lightpaper.saver.zip"
  name "Lightpaper"
  desc "Lightroom cache mosaic macOS screen saver"
  homepage "https://github.com/dmitri-b/lightpaper"

  depends_on macos: ">= :sonoma"

  screen_saver "Lightpaper.saver"

  caveats <<~EOS
    Lightpaper is not notarized. If macOS blocks it, clear the quarantine flag:
      xattr -dr com.apple.quarantine "~/Library/Screen Savers/Lightpaper.saver"

    Then choose Lightpaper in System Settings > Screen Saver.
  EOS
end
