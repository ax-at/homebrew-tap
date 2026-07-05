cask "pencil-dev" do
  version :latest
  sha256 :no_check

  on_arm do
    url "https://www.pencil.dev/download/Pencil-mac-arm64.dmg"
  end
  on_intel do
    url "https://www.pencil.dev/download/Pencil-mac-x64.dmg"
  end

  name "Pencil"
  desc "Design-to-code canvas desktop app (Pencil.dev)"
  homepage "https://www.pencil.dev/"

  # Token is "pencil-dev" (not "pencil") to avoid colliding with the unrelated
  # Evolus Pencil cask in homebrew-cask. The download URL is an unversioned,
  # moving "latest" pointer (302 -> a signed GCS URL), so there is nothing to
  # pin: version :latest + sha256 :no_check is the only workable pairing.
  # Pencil ships no auto-updater (updates are manual), so refresh with
  #   brew upgrade --cask --greedy pencil-dev
  depends_on macos: :monterey # LSMinimumSystemVersion = 12.0

  app "Pencil.app"

  zap trash: [
    "~/Library/Application Support/Pencil",
    "~/Library/Caches/dev.pencil.desktop",
    "~/Library/HTTPStorages/dev.pencil.desktop",
    "~/Library/Preferences/dev.pencil.desktop.plist",
    "~/Library/Saved Application State/dev.pencil.desktop.savedState",
  ]
end
