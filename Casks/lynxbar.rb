cask "lynxbar" do
  version "0.2.0"
  sha256 "3e83b0e1ced545d99e5349c60eae4393c32655b647ea828d03cf11d49aa23432"

  url "https://github.com/swnb/lynxbar/releases/download/v#{version}/LynxBar-#{version}-universal-unsigned.dmg"
  name "LynxBar"
  desc "Native, privacy-first macOS menu bar system monitor and AI quota tracker"
  homepage "https://github.com/swnb/lynxbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

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
