# Packaging and Team Deployment

## Free distribution pipeline (no Apple Developer account)

```bash
# One-time, and whenever the pinned runtime revision changes
./scripts/bootstrap_whisper_cpp.sh --skip-model
./scripts/update_runtime_provenance.sh

# Every release
./scripts/package_app.sh    # bundles runtime + icon, signs with hardened runtime
./scripts/create_dmg.sh     # produces dist/YappYapp.dmg; models download in-app
```

Publishing the DMG (GitHub release, appcast, cask, bridge) is a separate,
confirmed procedure: see "Publishing a release" in
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) and `./scripts/publish_release.sh`.

### Build machine and SDK

Every script that builds sources `scripts/lib/swift_sdk.sh`, which picks the
newest installed macOS SDK whose SwiftUI macros this toolchain can expand and
exports it as `SDKROOT`. With Command Line Tools only (no Xcode.app), the
macOS 27 SDK fails with "external macro implementation type
'SwiftUIMacros.StateMacro' could not be found", so the scripts fall back to the
macOS 26.5 SDK. `./scripts/doctor.sh` fails early with a plain message when no
installed SDK can build. Installing Xcode removes the fallback. An explicit
`SDKROOT` is always respected. CI selects the SDK the same way before its
strict build.

### Version and build number

`docs/RELEASE_PROVENANCE.json` (`app.short_version`, `app.bundle_version`) is
the only place the version lives; `package_app.sh` writes both into
Info.plist, and the cask template in `packaging/homebrew/yappyapp.rb` carries
the same version. Sparkle compares the build number, so every uploaded DMG
needs a new `bundle_version`, even a rebuild of the same version.
`./scripts/check_version_bump.sh` (run by `verify_release.sh`) fails when the
version or build matches the latest published release, using read-only `gh`
calls, and skips with a note when `gh` is missing or signed out.

Recipients double-click the DMG and drag YappYapp to Applications. A notarized
release then opens with a plain double-click. For a build that is not notarized
they follow the one-time first-open steps for their macOS version in
[GATEKEEPER.md](GATEKEEPER.md). On macOS 15 and macOS 26 that means System
Settings -> Privacy & Security -> Open Anyway; on macOS 14 it means right-click
-> Open. The DMG also ships a short FIRST-OPEN.txt with this guidance. After the
first open the app downloads models in-app and walks through the microphone and
Accessibility permissions.
<!-- GATEKEEPER-DOC-M2 -->

## Developer ID and notarization (removes the Gatekeeper warning)

From 0.4.0 on, releases are signed with a Developer ID Application
certificate and notarized, so they open with a normal double-click. Ad-hoc CI
candidates and source builds still use the self-signed "YappYapp Dev"
identity and need Open Anyway once. The Developer ID lane:

1. Join the Apple Developer Program and create a "Developer ID Application"
   certificate (and "Developer ID Installer" for a `.pkg`).
2. Store notary credentials once:

   ```bash
   xcrun notarytool store-credentials yappyapp-notary \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"
   ```

3. Build, check, notarize and staple:

   ```bash
   SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" ./scripts/package_app.sh
   ./scripts/notarization_preflight.sh --online
   ./scripts/notarize.sh
   ```

With a Developer ID identity, `scripts/package_app.sh` adds a secure
timestamp (`--timestamp`) to every signature (helpers, Sparkle parts, the
resource bundle and the app) and signs the app with a temporary copy of
`YappYapp.entitlements` that drops `disable-library-validation` (see below).

`scripts/notarize.sh` checks the signing authority with
`codesign -dv --verbose=4` (plain `codesign -dv` prints no `Authority=` lines,
which made earlier versions reject a valid Developer ID build), notarizes and
staples the app, recreates the DMG with the stapled app and signs the DMG with the
same Developer ID (`scripts/create_dmg.sh`), notarizes and staples
the DMG, then rewrites `dist/checksums.txt` so the published checksums match
the stapled files.

### Why `disable-library-validation` is still in the entitlements file

`YappYapp.entitlements` carries `com.apple.security.cs.disable-library-validation`.
With the hardened runtime, library validation only loads frameworks signed by
the same Team ID as the app. The "YappYapp Dev" identity has no Team ID, so
without this entitlement dyld rejects the embedded `Sparkle.framework` and the
app dies at launch. Keep it for as long as releases use the self-signed
identity, which source builds and ad-hoc candidates still use.

The entitlement also means a swapped framework inside the bundle would load
and inherit the app's Microphone and Accessibility grants, so Developer ID
builds do not carry it: `scripts/package_app.sh` strips it from a temporary
copy of the entitlements when `SIGN_IDENTITY` is a Developer ID Application
identity. The app and `Sparkle.framework` share the Team ID, so library
validation passes. 0.4.0 is the first such release; its notes tell users that
macOS asks for Accessibility and Microphone access once more, because the
signing identity changed.

## Recommended team path

For company-managed Macs, distribute YappYapp as a signed, notarized `.pkg` through MDM.

Recommended layers:

1. App bundle: signed and notarized.
2. Runtime package: either install Homebrew `whisper-cpp` to `/opt/homebrew/bin/whisper-cli`, or bundle tested `whisper-cli` and `whisper-server` binaries at `YappYapp.app/Contents/Resources/bin/`.
3. Model package: signed package that installs the Whisper model under `/Library/Application Support/YappYapp/models/` or each user's Application Support folder.
4. Glossary profile/package: managed `glossary.json` pushed by MDM.

Keeping the glossary separate lets the team update terminology without rebuilding the app.

The development packager copies `vendor/whisper.cpp/build/bin/whisper-cli` into the app bundle when that file exists. For a production team build, verify dynamic library dependencies before shipping a bundled CLI, or standardize on a managed Homebrew `whisper-cpp` install.

## Local development bundle

```bash
./scripts/package_app.sh
open dist/YappYapp.app
```

This produces a development app at:

```text
dist/YappYapp.app
```

`scripts/verify_release.sh` uses the same signing selection as
`scripts/package_app.sh`: an explicitly exported `SIGN_IDENTITY`, then the
stable local `YappYapp Dev` identity when installed, otherwise ad-hoc signing.
Set `SIGN_IDENTITY=-` explicitly when an ad-hoc artifact is required.

## CI release candidates

The `Release candidate` workflow (`.github/workflows/release-candidate.yml`)
is manual-only (`workflow_dispatch`), so pushing a tag never publishes a
candidate. It checks out the pinned `whisper.cpp` revision recorded in
`docs/RELEASE_PROVENANCE.json`, builds `whisper-cli` and `whisper-server`,
packages an ad-hoc app, creates a DMG, writes checksums, and uploads the
candidate artifacts.

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request: strict-concurrency build, unit tests, the built-in self-test, shell
checks, the install and settings smokes, and the source policy checks.

The candidate build refreshes the runtime hashes in its working copy with
`scripts/update_runtime_provenance.sh` after compiling `whisper.cpp`. This keeps
the manifest embedded in the candidate tied to the exact runner-produced
binaries without committing generated hashes back to the source branch.

These CI artifacts are for review and manual QA. They are not Developer ID
notarized, and they do not replace the final local `./scripts/verify_release.sh`
or clean-account manual QA. Developer ID notarization remains an optional
low-friction distribution upgrade unless a later trusted release workflow is
added with Apple Developer credentials.

## Stable local signing (keeps the Accessibility grant)

Ad-hoc signatures change on every build, so macOS revokes the Accessibility
permission after each rebuild. Create a stable self-signed identity once:

```bash
./scripts/create_signing_identity.sh
```

This generates a "YappYapp Dev" certificate, imports it into the login
keychain, and trusts it for code signing (one macOS password prompt).
`package_app.sh` automatically signs with this identity when it exists and falls
back to ad-hoc signing otherwise. Grant Accessibility to the next build once; after
that it survives rebuilds.

## Installer sketch

After signing the app, create a component package:

```bash
pkgbuild \
  --install-location /Applications \
  --component dist/YappYapp.app \
  dist/YappYapp.pkg
```

Then sign the package:

```bash
productsign \
  --sign "Developer ID Installer: YOUR COMPANY" \
  dist/YappYapp.pkg \
  dist/YappYapp-signed.pkg
```

## Homebrew cask

`packaging/homebrew/yappyapp.rb` is the canonical cask. `publish_release.sh`
fills in the version and the sha256 of the final DMG and copies it to
`migueltorrezd/homebrew-tap` (`Casks/yappyapp.rb`). Edit the cask here, never in
the tap. It requires Apple Silicon (`depends_on arch: :arm64`), quits the app on
uninstall, and its `zap` stanza deletes app data and runs
`tccutil reset All app.yappyapp.YappYapp`. Users install with
`brew install --cask migueltorrezd/tap/yappyapp`.

## The matd97 bridge

The project used to live under the GitHub account `matd97`, now renamed to
`migueltorrezd`. Builds up to 0.3.1 have this feed baked into Info.plist:

```text
https://raw.githubusercontent.com/matd97/yappyapp-releases/main/appcast.xml
```

and early Homebrew users tapped `matd97/tap`. Both still work only because
GitHub redirects renamed repositories. The redirect breaks for good if anyone
creates a repository with the same name under `matd97`. The `matd97` login was
re-registered on 2026-07-14 by an account the project does not control (0
public repositories when checked on 2026-10-16). If that happens, every 0.3.x
install stops receiving updates, including the update that would move it to
the new feed.

What the project does about it:

- From 0.4.0 on, Info.plist points at the `migueltorrezd` feed
  (`scripts/package_app.sh`), and `scripts/release_tooling_smoke.sh` fails if
  any shipped URL, script or cask points at `matd97` again.
- Ship releases while the redirect still works, so 0.3.x installs update to a
  build that polls the new feed.
- `matd97-bridge/` keeps the exact appcast and cask that old clients must see.
  `publish_release.sh` refreshes it after each release
  (`scripts/sync_matd97_bridge.sh`), and
  `scripts/sync_matd97_bridge.sh --check <appcast> [<cask>]` confirms it
  matches. If the redirect ever lapses and the `matd97` name can be recovered,
  publish these two files as `matd97/yappyapp-releases/appcast.xml` and
  `matd97/homebrew-tap/Casks/yappyapp.rb`.
- Keep the bridge until no 0.3.x installs remain. GitHub does not report
  traffic to raw feed files, so old installs cannot be counted; keep it for at
  least two releases after 0.4.0.

## Runtime network posture

The app should be shipped without a network entitlement if the final distribution uses hardened runtime entitlements. Runtime transcription does not need network access.

Setup scripts use network access to fetch `whisper.cpp` and model weights.
YappYapp fetches Parakeet files from exact Hugging Face revisions when the user clicks Download,
verifies each selected file's declared size plus LFS SHA-256 or Git blob SHA-1,
and stores them in FluidAudio's cache layout. FluidAudio's own network path is
forced offline and only loads a cache after YappYapp verifies its manifest. The optional LLM cleanup model
downloads once when a cleanup mode is picked, and only when the cleanup runtime
(`llama-completion` and `llama-server`, built by `scripts/bootstrap_llama_cpp.sh` and bundled by
`scripts/package_app.sh`) is present. While cleanup is on and "keep the model
warm" is set, the app keeps `llama-server` running on 127.0.0.1 (a free port
and a random path per launch, no web UI, no logs) so cleanup skips the model
load; transcripts reach it only in loopback request bodies. For managed deployment, fetch these
once in CI or on an admin machine, verify checksums and Parakeet integrity
manifests, then distribute signed artifacts internally.

Packaged builds make exactly one additional network call: a daily Sparkle
update check against the release feed pinned in Info.plist (`SUFeedURL`,
raw.githubusercontent.com). It transmits version numbers only, is controlled
by the "Automatic update checks" settings toggle (on by default), and never
runs in dev builds (no `SUFeedURL` in their bundle). Dictation audio and
transcripts never touch the network under any setting.
