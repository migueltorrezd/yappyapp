# Canonical cask for migueltorrezd/homebrew-tap (Casks/yappyapp.rb).
# scripts/publish_release.sh fills version and sha256 from the final DMG and
# copies this file into the tap and into matd97-bridge/Casks/. Edit here, not
# in the tap.
cask "yappyapp" do
  version "0.4.1"
  sha256 "9a938d0f1d29e3ec57777ba4fc9131d4f72190e1e23b5ccd0399b8a0d9ef182a"

  url "https://github.com/migueltorrezd/yappyapp-releases/releases/download/v#{version}/YappYapp-#{version}.dmg"
  name "YappYapp"
  desc "Local-only dictation with on-device Whisper and Parakeet transcription"
  homepage "https://yappyapp.app/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "YappYapp.app"

  uninstall quit: "app.yappyapp.YappYapp"

  zap script: {
        executable: "/usr/bin/tccutil",
        args:       ["reset", "All", "app.yappyapp.YappYapp"],
      },
      trash:  [
        "~/Library/Application Support/YappYapp",
        "~/Library/Application Support/YappYappLegacy",
        "~/Library/Caches/app.yappyapp.YappYapp",
        "~/Library/HTTPStorages/app.yappyapp.YappYapp",
        "~/Library/Preferences/app.yappyapp.YappYapp.plist",
        "~/Library/Saved Application State/app.yappyapp.YappYapp.savedState",
      ]

  caveats <<~EOS
    YappYapp needs an Apple Silicon Mac.

    Updating from 0.3.x? The app's signature changed in 0.4.0, so macOS asks
    for Accessibility and Microphone access once more: turn YappYapp on again
    in System Settings -> Privacy & Security -> Accessibility, and in
    System Settings -> Privacy & Security -> Microphone.

    Moving from the old tap? Run once:
      brew untap matd97/tap
  EOS
end
