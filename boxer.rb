cask "boxer" do
  version "4.4b5"
  sha256 "3a3a415b5b75052df375a90f90749caf44b10a5f8c4c7adb193f2fe16799f89e"

  url "https://github.com/dtseto/Boxer/releases/download/v#{version}/Boxer-#{version}.zip"
  name "Boxer"
  desc "DOS game emulator for macOS"
  homepage "https://github.com/dtseto/Boxer"

  app "Boxer.app"

  zap trash: [
    "~/Library/Application Support/Boxer",
    "~/Library/Caches/com.dtseto.boxer",
    "~/Library/Preferences/com.dtseto.boxer.plist",
    "~/Library/Saved Application State/com.dtseto.boxer.savedState",
  ]
end
