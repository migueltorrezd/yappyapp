# Contributing to YappYapp

YappYapp is built by Miguel Torrez: [LinkedIn](https://www.linkedin.com/in/miguel-torrez), [YouTube](https://www.youtube.com/@migueltorrezai), [GitHub](https://github.com/migueltorrezd).

Thanks for taking care of a local-first dictation app. The project is intentionally small enough to understand, but it touches sensitive macOS surfaces: microphone capture, Accessibility, clipboard, local model downloads, and app signing. Please keep changes boring and verifiable.

## Development Setup

YappYapp requires macOS 14 or newer. Apple Silicon is required:
the app and its bundled runtime are built for arm64 only.

```bash
git clone https://github.com/migueltorrezd/yappyapp.git
cd yappyapp
brew install whisper-cpp
./scripts/install_model.sh
./scripts/doctor.sh
swift run YappYapp
```

For a packaged app with the bundled `whisper.cpp` runtime:

```bash
./scripts/bootstrap_whisper_cpp.sh
./scripts/package_app.sh
open dist/YappYapp.app
```

The app stores user config, glossary, models, logs, and pet stats in:

```text
~/Library/Application Support/YappYapp/
```

## Required Checks

Run these before opening a pull request:

```bash
./scripts/doctor.sh
./scripts/run_tests.sh
./scripts/clean_install_smoke.sh
./scripts/package_app.sh
./scripts/launch_smoke.sh
./scripts/launchservices_smoke.sh
./scripts/create_dmg.sh
./scripts/dmg_smoke.sh
./scripts/release_artifacts_smoke.sh
./scripts/check_packaged_notices.sh
./scripts/check_docs_links.sh
./scripts/check_model_catalog_sync.sh
codesign --verify --deep --strict --verbose=2 dist/YappYapp.app
```

To run the built-in self-test against a scratch support folder instead of your
real `~/Library/Application Support/YappYapp/`, point
`YAPPYAPP_APP_SUPPORT_BASE` at an **absolute** path. A relative path resolves
against whatever directory each test happens to use, so some tests write
outside the folder you meant:

```bash
mkdir -p "$PWD/.build/selftest-support"
YAPPYAPP_APP_SUPPORT_BASE="$PWD/.build/selftest-support" .build/debug/YappYapp --self-test
```

For release candidates, run:

```bash
./scripts/verify_release.sh
```

`scripts/run_tests.sh` runs the built-in self-test harness plus a synthesized-speech end-to-end test when a local Whisper model is available. `scripts/clean_install_smoke.sh` uses `YAPPYAPP_APP_SUPPORT_BASE` and `--prepare-support` to verify first-launch setup in a temporary directory. `scripts/launch_smoke.sh` starts the packaged app executable in smoke mode, verifies isolated support files, then exits. `scripts/launchservices_smoke.sh` runs the same check through macOS `open -n`. `scripts/dmg_smoke.sh` mounts the generated DMG and verifies the app layout, bundle identity, notices, signature, and no-bundled-model posture. `scripts/check_packaged_notices.sh` confirms the signed app bundle carries the current project license, third-party notices, and release provenance.

## Architecture Guide

Start with:

- `ROADMAP.md`: current release status and contributor priorities.
- `docs/ARCHITECTURE.md`: pipeline and privacy model.
- `docs/OPEN_SOURCE_AUDIT.md`: current release-readiness findings.
- `Sources/YappYapp/AppDelegate.swift`: top-level app orchestration.
- `Sources/YappYapp/RecordingController.swift`: microphone and WAV capture.
- `Sources/YappYapp/WhisperTranscriber.swift`: CLI fallback.
- `Sources/YappYapp/WhisperServerController.swift`: warm local server.
- `Sources/YappYapp/ParakeetTranscriber.swift`: FluidAudio/CoreML ASR.
- `Sources/YappYapp/ClipboardInjector.swift`: paste and Accessibility behavior.

## Privacy Rules

- Do not add cloud transcription.
- Do not write transcript history to disk.
- Do not keep temporary audio after transcription, failure, or cancellation.
- Do not paste into secure input or password fields.
- Keep network usage limited to setup/runtime model downloads unless a feature explicitly documents otherwise.
- Be precise in docs: "local transcription" still allows model downloads before inference.

## Pull Request Expectations

- Keep changes focused. Large UI and app lifecycle changes are easy to regress.
- Explain any behavior change around microphone, Accessibility, clipboard, hotkeys, downloads, or signing.
- Add self-tests when the change is deterministic.
- Add manual QA notes for paste behavior in browsers, terminals, Electron apps, or native fields.
- Do not commit `.build/`, `dist/`, `vendor/`, models, audio recordings, logs, or local app support files.
- Contributions are accepted under the repository's MIT License.

## Manual QA Matrix

For changes that touch paste, recording, or app lifecycle, test at least:

- TextEdit or Notes native text field.
- A browser web text field.
- A terminal with a prompt focused.
- An Electron-style app if available.
- Start, stop, cancel, and auto-stop recording.
- Missing model or missing runtime state.
- Accessibility disabled and enabled.

## Release Notes

Release notes should include:

- User-visible changes.
- Privacy or permission changes.
- Model/runtime download changes.
- Known limitations.
- Verification commands and results.
