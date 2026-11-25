cask "lynxbar" do
  version "0.1.0"
  sha256 "c846a06609bf26a185e454b138d279fa4ce3418df727b9f97af3858c0308b9ab"

  url "https://github.com/swnb/lynxbar/releases/download/v#{version}/LynxBar-#{version}-universal-unsigned.dmg"
  name "LynxBar"
  desc "Native, privacy-first macOS menu bar system monitor and AI quota tracker"
  homepage "https://github.com/swnb/lynxbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "LynxBar.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/LynxBar.app"]
  end

  zap trash: [
    "~/Library/Application Support/LynxBar",
    "~/Library/Preferences/com.swnb.LynxBar.plist",
  ]
end
