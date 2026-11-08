# Homebrew-Cask für ZIPP.
#
# Für einen eigenen Tap (github.com/CasX61/homebrew-tap) diese Datei nach
# `Casks/zipp.rb` kopieren. Nach jedem Release `version` und `sha256` anpassen;
# beides steht in der Zusammenfassung des Release-Workflows.
#
#   brew install --cask casx61/tap/zipp
cask "zipp" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/CasX61/zipp/releases/download/v#{version}/ZIPP-#{version}.dmg"
  name "ZIPP"
  desc "Archiv-Manager: ZIP, 7z, RAR, TAR entpacken und erstellen"
  homepage "https://github.com/CasX61/zipp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "ZIPP.app"

  zap trash: [
    "~/Library/Preferences/app.zipp.ZIPP.plist",
    "~/Library/Saved Application State/app.zipp.ZIPP.savedState",
    "~/Library/Caches/app.zipp.ZIPP",
  ]
end
