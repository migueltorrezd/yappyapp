# Release Checklist

Use this before publishing a release, then follow "Publishing a release"
below. From 0.4.0 on, releases are signed with the Developer ID Application
identity and notarized (see [PACKAGING.md](PACKAGING.md)); ad-hoc candidates
and source builds still use the "YappYapp Dev" identity and the first-open
steps.

## Required Decisions

- `LICENSE` included and release notes state the project license.
- `docs/INSTALL.md` reviewed against the current app bundle, model defaults,
  and signing/notarization posture.
- Third-party/model notices reviewed and updated for the exact artifacts shipped.
- `./scripts/check_packaged_notices.sh` passes, confirming the app bundle
  includes the current project license, third-party notices, and release
  provenance manifest plus full local license texts for bundled runtime helpers
  and compiled Swift package dependencies.
- Bundle identifier verified for the release channel.
- Fresh support-directory setup verified under `~/Library/Application Support/YappYapp`.
- Signing path chosen: ad-hoc, local self-signed development, or Developer ID notarized release.
- If this release is not notarized, the release notes include the ready
  Gatekeeper / first-open block from the Release Notes Template below and link to
  [docs/GATEKEEPER.md](GATEKEEPER.md), and the install docs point to the same
  version-correct first-open steps (macOS 15 and macOS 26 use System Settings ->
  Privacy & Security -> Open Anyway; macOS 14 uses right-click -> Open). If the
  release should link to an online guide, set `REPO_URL` when running
  `./scripts/create_dmg.sh`; when unset, FIRST-OPEN.txt references the
  GATEKEEPER.md bundled in the DMG instead and never ships a placeholder
  URL. <!-- GATEKEEPER-DOC-M2 -->
- For an optional notarized release, `./scripts/notarization_preflight.sh --online` passes before running `./scripts/notarize.sh`.
- Runtime path chosen: bundled `whisper.cpp`, Homebrew dependency, or both.
- Model distribution policy reviewed in `docs/MODEL_DISTRIBUTION.md`.
- `./scripts/check_ignore_policy.sh` passes, confirming local build outputs,
  model weights, audio, transcripts, support reports, and release archives are
  ignored while source files remain trackable.
- `./scripts/check_docs_links.sh` passes, confirming public Markdown links point
  to files that exist in the repository.
- `./scripts/check_model_catalog_sync.sh` passes, confirming the Swift model
  picker, shell installer, and release provenance manifest expose the same
  Whisper model filenames and SHA-1 checksums.
- `./scripts/check_no_model_weights.sh` passes, unless the release
  intentionally ships model weights and the policy/provenance/checker were
  updated together.
- `./scripts/check_privacy_artifacts.sh` passes, confirming the source tree and
  packaged app do not contain recorded audio or transcript artifacts, and the
  app bundle has a clear local-first microphone usage description.
- `./scripts/check_network_policy.sh` passes, confirming runtime Swift network
  use stays limited to the local Whisper server and documented model-download
  paths, and that release entitlements do not add network access.
- `./scripts/check_release_binary_surface.sh` passes, confirming the packaged
  executable excludes self-tests, developer smoke commands, transcript samples,
  and config-path print labels while retaining only the intended launch,
  permission, and Parakeet-cache diagnostics used by release/support tooling.
- `docs/RELEASE_PROVENANCE.json` updated and `./scripts/check_provenance.sh` passes.
- `./scripts/check_hf_model_metadata.sh` passes against live Hugging Face model-card metadata.
- Release notes include the chosen runtime/model revisions and checksum posture from the provenance manifest.

## Build Verification

```bash
./scripts/verify_release.sh
```

The verifier runs the doctor, support-report smoke test, the standalone Swift
Testing target, built-in integration/UI tests,
clean-install support-folder smoke test, source-install smoke test, offline
managed-config smoke test, settings backup smoke test, reset app-data smoke
test, route-change device inventory, package build, packaged-app launch smoke,
LaunchServices smoke, release-binary surface check, packaged-notices check, ignore-policy check, documentation-link check,
model-catalog sync, model-weight policy check, privacy artifact policy check,
release metadata checks, provenance checks, bundle identifier/name checks,
live model-card metadata verification, code-signature verification, DMG creation, mounted-DMG smoke, checksum
generation, and release-artifact smoke.

The verifier uses an explicitly exported `SIGN_IDENTITY`, otherwise the stable
local `YappYapp Dev` identity when present, and falls back to ad-hoc signing.
Set `SIGN_IDENTITY=-` explicitly for an ad-hoc candidate or export a Developer
ID identity to verify that distribution lane.

The GitHub Actions `Release candidate` workflow runs the
core ad-hoc candidate packaging path only on `workflow_dispatch`, reconstructs the pinned
`whisper.cpp` runtime from `docs/RELEASE_PROVENANCE.json`, and uploads the DMG,
app zip, checksums, a manual QA report template, and a sanitized support report
as artifacts. Treat those artifacts as review candidates; they still need
provenance review, clean-account manual QA, and explicit non-notarized install
notes before source/ad-hoc distribution. Developer ID notarization is only needed
for the optional low-friction Mac distribution lane.

Run `./scripts/launchservices_smoke.sh` on release candidates to exercise the
macOS `open -n dist/YappYapp.app --args --launch-smoke` path with an isolated
support directory. It temporarily sets `YAPPYAPP_APP_SUPPORT_BASE` via
`launchctl` and restores it on exit.

## Manual QA

Generate a release-specific evidence template before testing:

```bash
./scripts/manual_qa_report.sh --run-launchservices-smoke > dist/manual-qa-report.md
```

Then complete the generated report on a clean user account or second Mac.

- Open `dist/YappYapp.app`.
- Confirm menu-bar icon appears.
- Open the popover from the menu-bar icon.
- Record and stop with `option-space`.
- Cancel recording with `esc`.
- Confirm temporary audio is removed after transcription.
- Confirm missing Accessibility permission copies instead of pasting.
- Confirm enabled Accessibility pastes into a native text field.
- Confirm browser or Electron fields receive text through paste fallback.
- Confirm terminal paste uses Cmd+V rather than direct AX value writes.
- Confirm secure input/password fields are not pasted into.
- Complete the target-app paste matrix in the generated manual QA report for
  native apps, browsers, Electron/WebView apps, terminals, secure fields, and
  the no-Accessibility fallback.
- Confirm Whisper model selection, download, and activation behavior.
- Confirm Parakeet model selection, first-run download, and warm reuse behavior.
- Confirm the shipped app package contains runtime helpers only, not bundled
  model weights, unless this release explicitly chose a pre-bundled model path.
- Confirm launch-at-login toggle behavior.
- Confirm settings export works and import dry-run previews the expected files.
- Confirm app-data reset dry-run lists only the intended local files.
- Confirm a real clean user account first launch after `./scripts/clean_install_smoke.sh` passes.
- Confirm `./scripts/launchservices_smoke.sh` passes before manual menu-bar QA.
- Run `./scripts/route_change_test.sh --list-devices`, then run
  `./scripts/route_change_test.sh --run` on a Mac with two input devices, or
  record that the live test skipped because only one input device was available.

## Release Artifacts

- `dist/YappYapp.app`
- `dist/YappYapp.dmg`
- `dist/checksums.txt` (written by `./scripts/write_checksums.sh`; rerun after
  anything that rewrites the DMG, such as notarization)
- `dist/release-<version>/` from `./scripts/stage_release_assets.sh`:
  `YappYapp-<version>.dmg`, `YappYapp.dmg` (byte copies of one file),
  `checksums.txt`, `checksum-line.md` and the filled-in cask `yappyapp.rb`
- Release notes
- License and third-party notice summary

## Publishing a release

Publishing touches three public places: the GitHub release in
`migueltorrezd/yappyapp-releases`, the appcast every installed copy polls, and
the Homebrew tap `migueltorrezd/homebrew-tap`. `./scripts/publish_release.sh`
prints every step below with its exact commands and runs nothing. With
`--execute` it asks before each step, and `--execute --from <n>` resumes after a
failure. Do every step in order; do not skip the checks.

Before you start:

- `docs/RELEASE_PROVENANCE.json` has a new `short_version` and a higher
  `bundle_version` than the latest release, and `./scripts/check_version_bump.sh`
  says OK. Never re-upload a DMG under a version that is already published:
  Sparkle compares the build number and would never offer the new file.
- `./scripts/verify_release.sh` passed with an explicit `SIGN_IDENTITY`
  (`SIGN_IDENTITY="Developer ID Application: <name> (<team id>)"`), then
  `./scripts/notarization_preflight.sh --online` and `./scripts/notarize.sh`
  ran, so `dist/YappYapp.dmg` is the final, stapled file and
  `dist/checksums.txt` matches it.
- `gh auth status` shows the `migueltorrezd` account, and the Sparkle EdDSA key
  is in the login keychain (`generate_appcast` reads it from there).

Steps:

1. **Preflight.** Clean tree, new version, final DMG present,
   `./scripts/release_artifacts_smoke.sh` passes.
2. **Stage the upload set.** `./scripts/stage_release_assets.sh` copies
   `dist/YappYapp.dmg` to `dist/release-<version>/YappYapp-<version>.dmg`
   (Sparkle and the cask use this name) and `YappYapp.dmg` (the evergreen name
   behind `releases/latest/download/YappYapp.dmg` on the website). It writes
   `checksums.txt`, the release-notes line `checksum-line.md` and the filled-in
   cask, all computed from the staged file.
3. **Release notes.** Start from the template below. Paste
   `checksum-line.md` unchanged; never type or copy a checksum from anywhere
   else (the v0.3.1 notes published a stale one). The script refuses notes
   without the staged line.
4. **GitHub release.** `gh release create v<version>` in
   `migueltorrezd/yappyapp-releases` with both DMGs and the notes.
5. **Check the uploads.** GitHub's `sha256:` digest for both assets must equal
   the staged checksum.
6. **Appcast.** Clone `yappyapp-releases`, run `./scripts/generate_appcast.sh`
   on a folder holding the current `appcast.xml` and only the new versioned
   DMG. It signs the DMG with the EdDSA key, keeps every earlier item and
   points each item at its own `v<version>` tag. The script checks that the
   new build is present and no earlier build was dropped, then commits and
   pushes `appcast.xml` to `main`.
7. **Cask.** Copy the staged `yappyapp.rb` to `Casks/yappyapp.rb` in
   `migueltorrezd/homebrew-tap`, commit and push.
8. **matd97 bridge.** `./scripts/sync_matd97_bridge.sh` copies the new appcast
   and cask into `matd97-bridge/`; commit it here. See
   [PACKAGING.md](PACKAGING.md), "The matd97 bridge".
9. **Live check.** The `migueltorrezd` feed and the old `matd97` feed URL both
   serve the new build, and both DMG download URLs return 200. Raw GitHub
   caches for about five minutes.
10. **Key backup.** Confirm the two backups below exist and are current.

After publishing, install the new DMG on a second Mac or clean account, and
let an older install update itself through Sparkle once.

### Key backup

Two secrets live only in the release Mac's login keychain. Back up both in the
password manager before the next release, and again whenever one changes.

- **Sparkle EdDSA private key.** It signs every update. Its public half
  (`SUPublicEDKey` in Info.plist) is baked into every installed copy. Lose it
  and no installed copy will ever accept another update; users must download a
  new DMG by hand. Export it with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-ed25519.key`,
  store the file contents in the password manager, then delete the file.
  Restore with `generate_keys -f <file>`. Check the public key with
  `generate_keys -p`; it must print the `SUPublicEDKey` value from
  `scripts/package_app.sh`.
- **"YappYapp Dev" signing identity.** macOS ties the Accessibility grant to
  it. Lose it and every user must grant Accessibility again after the next
  update. Export it from Keychain Access (My Certificates, YappYapp Dev,
  Export as `.p12` with a strong password) and store the file and the password
  in the password manager. When Developer ID arrives, back up that
  certificate the same way.

### Owner actions for the matd97 to migueltorrezd move

These are edits in public repositories, so they are not scripted. Paste the
text below as written.

**`migueltorrezd/homebrew-tap` README.md** (replace the whole file):

````markdown
# homebrew-tap

Homebrew tap for YappYapp, the local-only Mac dictation app. Apple Silicon
required.

```
brew install --cask migueltorrezd/tap/yappyapp
```

Installed from the old `matd97/tap`? Switch once:

```
brew untap matd97/tap
brew install --cask migueltorrezd/tap/yappyapp
```

Uninstall, including settings, models and privacy grants:

```
brew uninstall --zap --cask yappyapp
```
````

**`migueltorrezd/yappyapp-releases` README.md**, section "Install via
Homebrew" (replace the section; it drops the advice to strip quarantine):

````markdown
## Install via Homebrew

```
brew install --cask migueltorrezd/tap/yappyapp
```

Used the old `matd97/tap`? Run `brew untap matd97/tap` once, then the command
above. Recent Homebrew versions keep macOS quarantine on downloads, so the
first-open steps above apply to Homebrew installs too. YappYapp needs an Apple
Silicon Mac.
````

**v0.3.1 release body**, replace the last two paragraphs (the published
SHA-256 there is wrong; the asset digest on GitHub is the real one):

```markdown
**New install:** download the DMG below, drag to Applications, first-open steps in FIRST-OPEN.txt. Or: `brew install --cask migueltorrezd/tap/yappyapp` (used `matd97/tap` before? run `brew untap matd97/tap` first).

SHA-256 (YappYapp-0.3.1.dmg and YappYapp.dmg): 183902875c68b7c6fb629a68693600911392bb83bf4a28154260e3d84402ae9c
```

**v0.3.0 release body**, replace the "Or with Homebrew" paragraph:

```markdown
**Or with Homebrew:** `brew install --cask migueltorrezd/tap/yappyapp` (the first-open steps above still apply; used `matd97/tap` before? run `brew untap matd97/tap` first)
```

Also confirm who controls the `matd97` login (re-registered on 2026-07-14), and
keep publishing while the rename redirect still serves the old feed.

## Release Notes Template

```markdown
## YappYapp <version>

### Highlights

### Privacy And Permissions

<!-- GATEKEEPER-DOC-M2 ready first-open copy for non-notarized releases -->
First open on a non-notarized build (one time):
- macOS 15 Sequoia / macOS 26 Tahoe: open the app, click Done, then System
  Settings > Privacy & Security > Open Anyway > authenticate > Open.
- macOS 14 Sonoma: right-click the app > Open > Open.
Why: this YappYapp build is distributed outside the Mac App Store and is not
yet notarized. Full guide: docs/GATEKEEPER.md

### Models And Runtime

### Fixes

### Known Limitations

### Verification

- `./scripts/verify_release.sh`
- `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
- `./scripts/check_provenance.sh`
- `./scripts/check_hf_model_metadata.sh`
- `./scripts/check_packaged_notices.sh`
- `./scripts/check_ignore_policy.sh`
- `./scripts/check_docs_links.sh`
- `./scripts/check_model_catalog_sync.sh`
- `./scripts/check_no_model_weights.sh`
- `./scripts/check_privacy_artifacts.sh`
- `./scripts/check_network_policy.sh`
- `./scripts/check_release_binary_surface.sh`
- `./scripts/support_report.sh`
- `./scripts/source_install_smoke.sh`
- `./scripts/offline_config_smoke.sh`
- `./scripts/settings_backup_smoke.sh`
- `./scripts/reset_app_data_smoke.sh`
- `./scripts/launchservices_smoke.sh`
- `./scripts/dmg_smoke.sh`
- `./scripts/release_artifacts_smoke.sh`
- `./scripts/release_tooling_smoke.sh`
- `./scripts/notarization_preflight.sh --online` for Developer ID releases
- GitHub Actions `Release candidate` artifact set, when publishing from CI
- `dist/manual-qa-report.md` completed on a clean account or second Mac
- `dist/support-report.md` reviewed for private details
- Manual QA completed on macOS <version> / <hardware>
- `./scripts/route_change_test.sh --list-devices`
- `./scripts/route_change_test.sh --run` passed or skipped with reason
```
