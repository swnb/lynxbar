cask "lynxbar" do
  version "0.1.0"
  # Pin the exact SHA256 from SHA256SUMS.txt once the v0.1.0 signed DMG is published.
  sha256 :no_check

  url "https://github.com/swnb/lynxbar/releases/download/v#{version}/LynxBar-#{version}-universal.dmg"
  name "LynxBar"
  desc "macOS menu bar system monitor"
  homepage "https://github.com/swnb/lynxbar"

  depends_on macos: ">= :ventura"

  # Notarized and stapled; Gatekeeper opens directly
  app "LynxBar.app"

  zap trash: [
    "~/Library/Preferences/com.swnb.LynxBar.plist",
    "~/Library/Application Support/LynxBar",
  ]
end
