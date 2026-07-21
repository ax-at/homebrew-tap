cask "pencil-dev" do
  version "1.2.0,1784566797010925"
  sha256 :no_check

  # autobump-md5: EfyWMJx+Vn/eyGbE2tUXww==

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
  # moving "latest" pointer (302 -> a signed GCS URL) with no stable checksum,
  # so sha256 is :no_check and the version is a real-version + GCS-generation
  # hybrid ("<CFBundleShortVersionString>,<x-goog-generation>"). It is kept
  # current automatically by .github/workflows/autobump.yml (weekly); the
  # "# autobump-md5:" line above is the pipeline's byte-change detector.
  # See DECISIONS.md for the full rationale.
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
