# Installing YappYapp

YappYapp is a local macOS menu-bar dictation app. Transcription runs on this
Mac after a model is installed. The app does not require an OpenAI API key or
any cloud transcription account.

## Requirements

- macOS 14 or newer.
- Apple Silicon required (M1 or newer). The app is built for arm64 only and
  does not run on Intel Macs.
- Microphone permission.
- Accessibility permission if you want YappYapp to paste into other apps.
- A local speech model:
  - Whisper GGML model under `~/Library/Application Support/YappYapp/models/`.
  - Or a Parakeet CoreML model downloaded and integrity-verified by YappYapp
    into FluidAudio's cache layout when you click Download in guided setup or
    on the Models tab.

## Install From A Release DMG

1. Download `YappYapp.dmg` from the release page.
2. Open the DMG.
3. Drag `YappYapp.app` to `/Applications`.
4. Open YappYapp.
5. Release DMGs (0.4.0 and later) are notarized and open with a double-click;
   click Open when macOS asks about an app from the internet. If the build is
   not notarized (a source or CI build), follow the one-time first-open steps for your
   macOS version in [docs/GATEKEEPER.md](GATEKEEPER.md). On macOS 15 and macOS
   26 you open System Settings -> Privacy & Security and click Open Anyway; on
   macOS 14 you right-click `YappYapp.app` and choose Open. <!-- GATEKEEPER-DOC-M2 -->
6. Click the menu-bar icon to open the popover.
7. Grant microphone permission when macOS asks.
8. Grant Accessibility permission when you want automatic paste into other
   apps. Without Accessibility, YappYapp keeps the transcript on the clipboard
   for manual paste.

The first launch creates:

```text
~/Library/Application Support/YappYapp/config.json
~/Library/Application Support/YappYapp/glossary.json
~/Library/Application Support/YappYapp/models/
```

## Install With Homebrew

```bash
brew install --cask migueltorrezd/tap/yappyapp
```

The cask installs the same DMG and checks the same SHA-256 as the release
page, and it refuses to install on an Intel Mac. The one-time first-open steps
above still apply, because Homebrew keeps the macOS quarantine flag.

Installed from the old `matd97/tap`? Switch once:

```bash
brew untap matd97/tap
brew install --cask migueltorrezd/tap/yappyapp
```

YappYapp updates itself through Sparkle either way, so Homebrew does not need
to upgrade it.

## Install From Source

Install the command-line dependencies:

```bash
xcode-select --install
```

Clone the repository, then run the guided setup from the project directory.
The setup creates support files, installs or selects
a local `whisper-cli` runtime when requested, optionally installs Whisper model
weights, and runs the doctor:

```bash
git clone https://github.com/migueltorrezd/yappyapp.git
cd yappyapp
./scripts/setup_source_install.sh
swift run YappYapp
```

The setup script is conservative by default. `./scripts/setup_source_install.sh`
without `--model` preserves Parakeet Ultra as the selected engine and does not
download model weights. Useful variants:

```bash
./scripts/setup_source_install.sh --runtime auto
./scripts/setup_source_install.sh --runtime homebrew --model large-v3-turbo
./scripts/setup_source_install.sh --runtime source --model tiny.en
./scripts/setup_source_install.sh --runtime none --skip-doctor
```

Maintainers can verify the no-download source setup path in an isolated support
directory:

```bash
./scripts/source_install_smoke.sh
```

If you plan to rebuild often, create a stable local signing identity so macOS
does not forget the Accessibility permission on every rebuild:

```bash
./scripts/create_signing_identity.sh
./scripts/package_app.sh
open dist/YappYapp.app
```

## Install Models

New installs default to Parakeet Ultra, which YappYapp downloads from a pinned
Hugging Face revision and verifies before FluidAudio loads it. To install the
recommended high-quality multilingual Whisper option:

```bash
./scripts/install_model.sh
```

Install a specific Whisper model:

```bash
./scripts/install_model.sh tiny.en
./scripts/install_model.sh small
./scripts/install_model.sh medium
```

Install every Whisper model exposed in the picker:

```bash
./scripts/install_model.sh --all
```

List the exact supported model names:

```bash
./scripts/install_model.sh --list
```

The script stores files in:

```text
~/Library/Application Support/YappYapp/models/
```

It verifies downloaded Whisper files against the SHA-1 values registered in
the app and refuses unsupported model names instead of installing unverified
files. YappYapp downloads Parakeet files into FluidAudio's cache layout from
pinned revisions, verifies each declared size and LFS SHA-256 or Git blob SHA-1,
and writes an owner-only integrity manifest unless model downloads are disabled.

## Offline Or Managed Installs

For air-gapped Macs, classrooms, company-managed laptops, or MDM deployments:

1. Install the app bundle or signed package.
2. Install Whisper model files ahead of time into
   `~/Library/Application Support/YappYapp/models/` for each user, or use a
   managed location and set `modelPath` in `config.json`.
3. If using Parakeet, pre-cache the chosen FluidAudio CoreML model and its valid
   `.yappyapp-integrity-v1.json` manifest for the user before disabling downloads.
4. Set `allowModelDownloads` to `false` in `config.json`.
5. Run:

```bash
./scripts/doctor.sh
```

The doctor should report:

```text
OK   Whisper models installed ...
OK   configured Whisper model exists ...
OK   configured Whisper model checksum verifies ...
OK   model downloads are disabled in config.json
```

For custom managed model filenames without a registered checksum, the doctor
prints a warning so the deployment owner can confirm integrity through their
own package or MDM pipeline.

When downloads are disabled, the app treats an unverified Parakeet selection as
not ready and shows manual-install guidance instead of starting a network
download.

Maintainers can verify this posture without touching their real profile:

```bash
./scripts/offline_config_smoke.sh
```

## Check An Install

Run the doctor:

```bash
./scripts/doctor.sh
```

Useful successful signals:

- `packaged whisper-cli is bundled`, or a system `whisper-cli` is found.
- `Whisper models installed ...` when using a Whisper model.
- `config.json is valid JSON`.
- `configured Whisper model exists ...` when the selected model is a Whisper
  file, or `selected model uses Parakeet ...` for Parakeet.
- `selected Parakeet model cache is installed ...` when using a pre-cached
  Parakeet model, or `selected Parakeet model cache is missing; downloads are
  allowed for first use` for normal online first-run installs.
- `configured Whisper model checksum verifies ...` for known Whisper models
  from the supported picker.
- `configured whisper-cli is executable ...` when the selected model is a
  Whisper file.
- `model downloads are allowed` for default public builds, or `model downloads
  are disabled` for managed/offline builds.
- `dist/YappYapp.app code signature verifies` when using a packaged app.
- `microphone permission is granted`, or `microphone permission has not been
  requested yet` before first recording.
- `Accessibility permission is granted for auto-paste`, or `Accessibility
  permission is not granted yet` when clipboard-only fallback is expected.

For a bug report, prefer the sanitized support report. Review it before posting;
it is designed to avoid audio, transcripts, glossary entries, config contents,
and app logs. In the app, open SETUP, scroll to SUPPORT and click COPY SUPPORT
REPORT. That section also lists recent YappYapp crash reports by name and date,
with a REVEAL button. From a source checkout you can run the script instead:

```bash
./scripts/support_report.sh
```

## Troubleshooting

### The App Opens But Nothing Appears

YappYapp is a menu-bar app. Look for the menu-bar icon; it does not show a
normal Dock window.

### macOS Says The App Cannot Be Opened

The full one-time first-open steps are in [docs/GATEKEEPER.md](GATEKEEPER.md).
On macOS 15 and macOS 26 the working path is System Settings -> Privacy &
Security -> Open Anyway; on macOS 14 you right-click `YappYapp.app` and choose
Open. Release DMGs from 0.4.0 on are notarized and do not need these steps.
<!-- GATEKEEPER-DOC-M2 -->

### Dictation Records But Does Not Paste

Grant Accessibility permission:

```text
System Settings -> Privacy & Security -> Accessibility -> YappYapp
```

If you rebuild from source often, use `./scripts/create_signing_identity.sh`
before packaging so macOS keeps the Accessibility grant across rebuilds.

### The Model Is Missing

Install the recommended Whisper model:

```bash
./scripts/install_model.sh
```

Then run `./scripts/doctor.sh` again.

If the doctor still reports `configured Whisper model is missing`, open
`~/Library/Application Support/YappYapp/config.json` and check that `modelPath`
points to the model file you installed.

### Back Up Or Restore Settings

Export config, glossary, and pet stats before reinstalling, switching machines,
or testing a new build:

```bash
./scripts/export_settings.sh ~/Desktop/yappyapp-settings.zip
```

Preview a restore without changing anything:

```bash
./scripts/import_settings.sh ~/Desktop/yappyapp-settings.zip
```

Apply a restore:

```bash
./scripts/import_settings.sh --apply ~/Desktop/yappyapp-settings.zip
```

The import command creates a pre-import backup automatically before writing
settings. These scripts intentionally exclude models, audio, transcripts, logs,
and temporary files.

### Reset Local App Data

Preview exactly which local files would be reset:

```bash
./scripts/reset_app_data.sh
```

Delete only config, glossary, pet stats, logs, and smoke markers:

```bash
./scripts/reset_app_data.sh --apply --backup ~/Desktop/yappyapp-before-reset.zip
```

Downloaded models and previous settings backups are preserved by default. To
remove those too, add `--include-models` or `--include-backups` after reviewing
the dry-run output.

### Offline Mode Still Tries To Download

Confirm `config.json` contains:

```json
"allowModelDownloads": false
```

Then restart YappYapp. Whisper and YappYapp's pinned Parakeet downloads will be
blocked. FluidAudio is already forced offline in every configuration, so its
load/recovery path cannot fetch missing or mutable cache files.

### A Previous YappYapp Install Exists

Existing settings and models stay in:

```text
~/Library/Application Support/YappYapp/
```

Run `./scripts/doctor.sh` after first launch to verify the active support folder.

## Uninstall

Quit YappYapp from its menu-bar icon (right-click, then Quit), then remove it.

With Homebrew, one command removes the app, its settings and models, and its
privacy grants:

```bash
brew uninstall --zap --cask yappyapp
```

By hand:

1. Drag `/Applications/YappYapp.app` to the Trash.
2. Delete its settings, glossary, pet stats and Whisper models:

   ```bash
   rm -rf ~/Library/Application\ Support/YappYapp
   rm -rf ~/Library/Application\ Support/YappYappLegacy
   rm -rf ~/Library/Caches/app.yappyapp.YappYapp
   rm -rf ~/Library/HTTPStorages/app.yappyapp.YappYapp
   rm -f ~/Library/Preferences/app.yappyapp.YappYapp.plist
   ```

3. Remove the Microphone and Accessibility grants, so a later reinstall starts
   clean instead of showing a stale Accessibility entry:

   ```bash
   tccutil reset All app.yappyapp.YappYapp
   ```

4. Parakeet models live in FluidAudio's shared cache,
   `~/Library/Application Support/FluidAudio/Models/`. Other apps built on
   FluidAudio can use the same folder, so neither the cask nor these steps
   delete it. Remove the `parakeet-*` folders there yourself if nothing else
   needs them.

To keep your glossary and pet for later, run
`./scripts/export_settings.sh ~/Desktop/yappyapp-settings.zip` first.
