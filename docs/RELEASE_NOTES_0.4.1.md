# YappYapp 0.4.1

Version 0.4.1 (build 7). Apple Silicon, macOS 14 or newer.

A maintenance release. Nothing changes in how you dictate; your voice still
never leaves your Mac.

- **Updater library.** The built-in updater now uses Sparkle 2.10.0 (was
  2.9.4). Updates are still checked against the same signing key.
- **Speech engine library.** FluidAudio 0.17.7 (was 0.17.3) runs Parakeet.
  The Parakeet models, their pinned versions and their download addresses are
  unchanged, so nothing downloads again.
- **Build and tests.** The test library moves to swift-testing 6.4.1, and the
  project's automated checks use the current GitHub Actions versions.

## Install

Download `YappYapp-0.4.1.dmg`, check its SHA-256 against the value on the
release page, and drag YappYapp to Applications. It is signed with a Developer
ID and notarized, so it opens with a double-click. Homebrew:
`brew install --cask migueltorrezd/tap/yappyapp`. If you already run 0.4.0,
the built-in updater offers 0.4.1 and your permissions stay as they are.

**Updating straight from 0.3.x:** macOS asks for Accessibility and Microphone
access once more, because 0.4.0 changed how the app is signed. Turn YappYapp
back on in System Settings > Privacy & Security > Accessibility and >
Microphone.

Uninstall: `brew uninstall --zap --cask yappyapp`, or the manual steps in
`docs/INSTALL.md`.
