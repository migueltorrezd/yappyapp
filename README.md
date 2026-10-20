# YappYapp

Local-first dictation for macOS on Apple Silicon. Press a shortcut, talk, and
the text lands in whatever field you are typing in. Speech is transcribed on
your Mac with NVIDIA Parakeet (through FluidAudio) or OpenAI Whisper (through
whisper.cpp). No account, no API key, no cloud transcription.

YappYapp is open source under the [MIT License](LICENSE). Model weights and
bundled runtimes keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Download

- **DMG:** [YappYapp.dmg (latest release)](https://github.com/migueltorrezd/yappyapp-releases/releases/latest/download/YappYapp.dmg),
  or browse every build on the
  [releases page](https://github.com/migueltorrezd/yappyapp-releases/releases).
  Release builds are signed with an Apple Developer ID and notarized, so they
  open with a normal double-click (see [docs/GATEKEEPER.md](docs/GATEKEEPER.md)).
- **Homebrew:**

  ```bash
  brew install --cask migueltorrezd/tap/yappyapp
  ```

Installed apps update themselves through Sparkle. Requirements: macOS 14 or
newer on Apple Silicon (Intel Macs are not supported). Full install, offline
and managed-Mac instructions are in [docs/INSTALL.md](docs/INSTALL.md).

## Build from source

You need macOS 14+ on Apple Silicon, the Xcode Command Line Tools (or Xcode),
and `cmake` for the optional runtimes (`brew install cmake`).

```bash
git clone https://github.com/migueltorrezd/yappyapp.git
cd yappyapp

# Optional runtimes, pinned in docs/RELEASE_PROVENANCE.json and built into vendor/:
./scripts/bootstrap_whisper_cpp.sh --skip-model   # whisper-cli and whisper-server (Whisper models)
./scripts/bootstrap_llama_cpp.sh                   # llama.cpp helpers (cleanup, translation, Qwen3-ASR)

# Pick a macOS SDK that can build the SwiftUI macros (needed with Command Line Tools only):
source scripts/lib/swift_sdk.sh && yappyapp_use_buildable_sdk

swift build --disable-sandbox
.build/debug/YappYapp --self-test        # built-in test suite, touches no user data

./scripts/package_app.sh                 # dist/YappYapp.app, bundling the runtimes built above
open dist/YappYapp.app
```

Parakeet, the default engine, needs neither bootstrap script: the app
downloads the model on first run and verifies it. Run `./scripts/doctor.sh`
to check a local setup, and `./scripts/create_signing_identity.sh` once to
create a stable local signing identity so the Accessibility grant survives
rebuilds. Contributors: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository layout

- `Sources/` - app source (`YappYapp` target).
- `Tests/` - Swift Testing target (`YappYappTests`).
- `Resources/` - app icon, DMG background and Info.plist localizations.
- `scripts/` - setup, model install, packaging, smoke tests, release checks and support tools.
- `docs/` - architecture, install, packaging, Gatekeeper, model distribution, release checklist and provenance.
- `design/` - pet sprite artwork.
- `packaging/homebrew/` - the Homebrew cask template.
- `matd97-bridge/` - legacy appcast and Homebrew cask for installs that still poll the feed of the project's former GitHub handle (`matd97`); see [docs/PACKAGING.md](docs/PACKAGING.md).
- `.github/` - Dependabot, issue and PR templates, CI workflows.
- `Package.swift`, `Package.resolved` - Swift package definition and lockfile.
- `YappYapp.entitlements` - app entitlements.

Build outputs (`.build/`, `dist/`) and the vendored runtime sources (`vendor/`) are gitignored.

## Overview

YappYapp is a local-first macOS menu-bar dictation app for Apple Silicon. It records a short voice note, transcribes it on-device with NVIDIA Parakeet through FluidAudio or OpenAI Whisper through `whisper.cpp`, applies a personal glossary, then inserts the transcript into the focused text field. Parakeet Ultra is the default; on first run, DETECT BEST MODELS checks your Mac and the languages you speak and proposes the speech, cleanup and translation models before anything downloads. If no editable field is focused, the transcript stays on the clipboard.

The app is intentionally boring from a compliance perspective: no OpenAI API key, no cloud transcription, no transcript history, and temporary audio is deleted after each transcription.

## What it does

- Toggle recording with `⌥ space` from any app, cancel with `esc`. Setup > Dictation rebinds it, switches to Hold (push to talk) or Hybrid (tap toggles, hold talks), adds an optional one-key trigger (Right Option, Right Command, Right Control or Fn) and a Paste Last shortcut that re-pastes your most recent dictation from memory.
- Use either surface: clicking the menu-bar icon opens the Brutalist popover, while a manual launch or reopen presents a 440 x 596 control window with the same five tabs (it also opens on its own while setup is incomplete, never at login once setup is done). The icon turns red while recording. Right-click it for Start/Stop Dictation, a language switcher, and Quit.
- Keep an in-memory history of the last 10 transcripts, each with a Copy action (the indicator shows COPIED, then shrinks back). History clears when the app quits and never touches disk.
- Quiet voice boost (on by default): every recording is loudness-normalized before transcription, the decoder keeps low-energy segments it would otherwise drop as silence, and beam search handles hard audio. Makes whispered dictation work.
- Remove filler words (um, uh, euh, hmm) deterministically after transcription (toggle in Setup).
- Spoken edit commands (on by default, toggle in Setup): say "new line", "new paragraph" or "scratch that" as its own phrase. French ("nouvelle ligne", "nouveau paragraphe", "efface ça"), Spanish ("nueva línea", "nuevo párrafo", "borra eso") and Dutch ("nieuwe regel", "nieuwe alinea", "wis dat") work too. A command only counts between pauses, so "a new line of shoes" stays as spoken.
- Undo Last Dictation (menu, or an optional shortcut) takes the last dictation back out: exactly, when it was typed into the same field and is still there, or with Cmd+Z when it was pasted into the app still in front. Otherwise it says why it cannot.
- Retry Last Dictation (menu, an optional shortcut, or RETRY on the HUD and MIC tab after a failure) transcribes the last recording again with the current model and settings. The audio is kept in memory only, cleared by the next dictation and on quit.
- Translate a dictation into English, French, Spanish, Dutch, German, Portuguese, Italian, Japanese, Chinese or Korean (Setup > DICTATION > TRANSLATE TO). Translation runs on this Mac after cleanup through the bundled llama.cpp runtime with a pinned Hy-MT2 model (Apache-2.0): Hy-MT2 1.8B (about 1.1 GB, FAST, the default) or Hy-MT2 7B (about 4.6 GB, BEST). Whisper's built-in translate stays available for English with a Whisper model, no download. With Keep the model loaded on, the chosen model stays warm in a local `llama-server`, so a translation takes about 0.3 s with 1.8B and under 1 s with 7B instead of reloading the model each time; until it is ready the one-shot run takes over. If the model is missing or fails, the dictation goes out untranslated and the app says why.
- SCAN MY MAC on the MODELS tab reads the chip, memory, macOS version, free disk and power source, then suggests a speech model, a cleanup mode and a translation model that fit, with USE THIS on each. It never suggests a download that would leave less than 5 GB free.
- Optional local LLM cleanup: a small model on this Mac tidies what you said before it is pasted. Modes: AS SPOKEN (no model, exactly what you said), CLEAN (removes um and uh, adds punctuation and capitals, applies "no wait" corrections, keeps your words), EMAIL (Clean, laid out as an email body), LIST (one item per line) and NOTES (short note lines, every fact kept). Setup and onboarding explain the chosen mode with a "you say, it writes" example. The packaged app bundles a pinned llama.cpp runtime; the Qwen 2.5 1.5B model (about 1.1 GB) downloads only when you pick a mode, with progress, CANCEL and a checksum check. Spoken self-corrections ("monday, no wait, tuesday") are resolved before the model runs, and any rewrite that adds words, changes language or answers instead of tidying is thrown away for the raw transcript, with the reason shown.
- Numbers (Setup > DICTATION > NUMBERS): AS SPOKEN (the default, whatever the speech model wrote), DIGITS ("twenty five people" becomes "25 people", "three point five percent" becomes "3.5%") or WORDS ("25 people" becomes "twenty-five people"). It works with cleanup off, in English, French, Spanish and Dutch (other languages are left as they are). DIGITS converts numbers of 10 and up, decimals, years and numbers before a unit or percent; a lone small number like "one" stays a word ("one of them", "un ami"). WORDS keeps years, times, versions, codes, phone numbers, numbers over 999,999 and digits inside names ("GPT-5", "iOS 26"). Snippet phrases and your WORDS are never rewritten. An app profile can pick its own style, for example DIGITS for a terminal.
- Snippets: say a phrase such as "my email address" and get the stored text. Words and snippets import and export as JSON or CSV, with a preview before anything is saved. See [docs/WORDS_FILES.md](docs/WORDS_FILES.md).
- Per-app profiles: a dictation that ends in a chosen app can use its own language, cleanup mode, paste behavior, model and number style. VoiceOver reads the profile, language and model on the indicator while you dictate.
- Live preview (optional, Parakeet only): the last words you said show in a strip above the indicator while recording (bottom and top positions). It is never pasted and never saved.
- Transcribe an audio or video file on the FILES tab: drop it there (or on MIC), use CHOOSE FILE, or pick Transcribe Audio File from the menu. Progress, CANCEL and the results (COPY, SAVE as text) live on FILES, in memory only. FILES is separate from MIC: a file transcript never enters the dictation history, PASTE LAST or the clipboard until you press COPY, and it is never pasted.
- Mic check during first setup and in Setup: say something and see whether the mic hears you, with a plain verdict (too quiet, good, very loud).
- Text size (Small, Default, Large, Larger) in Setup > App, a keyboard focus ring when macOS Keyboard navigation is on, and VoiceOver announcements of each phase and paste outcome.
- Copy or save a sanitized support report (versions, model and settings only; no audio, transcripts, words or user names) and see recent crash reports from Setup > Help.
- Smart spacing: inserting next to existing text adds the space instead of gluing words together.
- Choose where the recording indicator appears (bottom, top, left, right, or hidden) and toggle the sounds.
- Guided first run in six steps: app language and the languages you speak, DETECT BEST MODELS (hardware scan, picks with sizes and reasons, USE THESE before any download), microphone, auto-paste, WORDS AND SNIPPETS (add one word and one snippet, saved to WORDS) and a test dictation that checks both. BACK on every step, SKIP where it is safe, and permission grants are picked up live.
- Dropdowns float over the screen under their field, so opening one never moves anything; arrow keys, Return and Escape work, and a click outside closes it.
- Use the app in English, French, Spanish or Dutch. It follows the Mac's language by default; the first step of setup and Setup > App > App language pick one directly, applied at once. This only changes the interface, never the dictation language.
- Keep the Whisper model warm in a local `whisper-server` process, so transcription starts instantly instead of reloading the model every time (Keep the model loaded in Setup > Speed, falls back to `whisper-cli` automatically).
- Hear a start sound when recording begins and a stop sound when recording ends.
- Always-on indicator on every display (Wispr style): a tiny pill at the edge of each screen that grows into a compact bar the moment dictation starts, then collapses back. No words in the bar: color, a glyph and the live level meter show the state, and VoiceOver reads it. Click-through except for stop, KEEP and RETRY, above full-screen apps, position configurable (bottom, top, left, right, or hidden). On the left and right it is a thin vertical bar centered on that edge. The pixel pet lives on it everywhere: standing on the bar at the bottom, hanging under it at the top (so the menu bar and the notch never cut it off), and sitting on the bar's upper end on the left and right, facing the screen. The indicator never takes focus: it is a non-activating panel, only the bar itself takes clicks (and only while it shows stop, KEEP or RETRY), so clicking an app under it, such as a terminal prompt at the bottom of the screen, reaches that app.
- Record microphone audio to a temporary local WAV file, from the system default or a chosen input device.
- Two engines, one list: pick any Whisper model (whisper.cpp, with one-click downloads) or any NVIDIA Parakeet model (CoreML via FluidAudio: Ultra, the most accurate multilingual one; TDT v3 multilingual; v2 English flagship; 110M tiny; Japanese) from the Models tab. Parakeet models download in one click (guided setup offers the recommended one), stay warm in-process, and are dramatically faster than Whisper Large.
- Qwen3-ASR for the languages Parakeet does not cover: the QWEN3-ASR group on MODELS offers Qwen3-ASR 0.6B (about 1 GB) and 1.7B (about 2.5 GB), Apache-2.0 models from Alibaba's Qwen team that recognize 52 languages and dialects, including Chinese, Japanese, Korean, Arabic and Hindi. On AUTO the model detects the language itself; a picked dictation language is passed as a hint, and it never translates. It runs through the bundled llama.cpp runtime: with Keep the model loaded on, the selected size stays warm in a local `llama-server` (about 0.15 s per short dictation with 0.6B and 0.3 s with 1.7B on an M5 Pro), otherwise the one-shot `llama-mtmd-cli` runs (about 1 s). Long recordings are cut into four-minute parts at quiet moments. FILES transcription works with it too. Each model is two pinned files, both SHA-256 verified, and a downloaded size you are not using can be deleted from its row.
- Bias transcription with your WORDS: the spellings go to Whisper as its prompt and to Qwen3-ASR as its context (on test clips, Qwen3-ASR spelled 10 of 12 unusual names right with them, 3 without).
- Apply deterministic glossary corrections after transcription: the "sounds like" swaps, then close misses of your words ("jenial" written "Genial") even with cleanup off. Everyday words are never rewritten, so "¡qué genial!" stays as said. With a cleanup mode on, the model also fixes near misses of your words when the sentence uses them as names.
- Learn from my fixes (on by default, Setup > Dictation): when you retype a name YappYapp got wrong right after it pasted, it learns your spelling, says "Learned Genial." with UNDO, and marks it LEARNED in WORDS. Deleted or undone words are never learned again.
- Insert into the focused text field through Accessibility first; the clipboard is only used when that fails. Never types into secure (password) fields, and names the app holding secure input when it can.
- Honest outcomes: the indicator turns green only for a confirmed paste; the MIC tab says PASTED (with the time it took), PASTED? (⌘V sent but not confirmed), COPIED or NOT PASTED (with the reason; the text stays in HISTORY). The pet celebrates confirmed pastes only.
- Never loses a transcript: a dictation that finishes after a newer one started is copied and announced instead of dropped. If you switch apps mid-dictation, it pastes into the app you are in when it is ready.
- A notification with a Copy button when a dictation fails or does not land while YappYapp is closed. No transcript text in the notification unless you turn that on.
- Esc cancels a dictation (optional), with UNDO for 5 seconds. A countdown shows in the last 10 seconds before the time limit.
- Put the previous clipboard back after every paste. Clipboard writes are marked transient and stay on this Mac (no Universal Clipboard); password-manager items are never restored.
- Start at login (toggle in Setup).
- Pixel pet gamification: 12 pets (4 unlock through milestones and hatch from eggs), per-pet levels every 250 words, daily quests with double XP, a once-a-week streak saver, lifetime word milestones with confetti storms, level-gated wardrobe accessories, idle micro-events, per-pet chiptune jingles, and a shareable weekly recap card saved to `~/Pictures/YappYapp` (never overwritten). Setup > App > Pet and quests turns all of it off; word counts and the streak still count.
- Surface setup issues (engine, model, paste permission) as a checklist with one-click fixes, or manual-install guidance when downloads are disabled.

## Runtime requirements

- macOS 14 or newer.
- Apple Silicon required (arm64 only; Intel Macs are not supported).
- Parakeet Ultra (or TDT v3) downloaded with one click in guided setup or Models, integrity-verified by YappYapp into FluidAudio's cache layout, or a local Whisper model plus `whisper-cli` from `whisper.cpp`.
- The packaged app includes the Whisper runtime helpers for users who choose a Whisper model; source builds can use Homebrew or the vendored runtime.
- Microphone permission.
- Accessibility permission for automatic paste.
- About 1.1 GB of free disk for the optional LLM cleanup model, and about 630 MB for Parakeet Ultra (about 480 MB for Parakeet TDT v3).
- Managed Macs can force settings through a configuration profile: [docs/MANAGED_INSTALLS.md](docs/MANAGED_INSTALLS.md).

Note: run `./scripts/create_signing_identity.sh` once to create a stable "YappYapp Dev" signing identity. Without it the app is ad-hoc signed and every rebuild invalidates the Accessibility grant. With it, grant Accessibility once and it survives rebuilds.

## Quick start from source

```bash
git clone https://github.com/migueltorrezd/yappyapp.git
cd yappyapp
./scripts/setup_source_install.sh
swift run YappYapp
```

The default setup preserves Parakeet Ultra as the selected engine and does not
download model weights. If `whisper.cpp` is already installed,
`--runtime auto` detects it. Use `--runtime homebrew --model large-v3-turbo` to
install and select the recommended Whisper option, or `--runtime source` to
build the pinned vendored runtime.

The first launch creates:

```text
~/Library/Application Support/YappYapp/config.json
~/Library/Application Support/YappYapp/glossary.json
~/Library/Application Support/YappYapp/models/
```

Edit `glossary.json` to add company terms and common mistranscriptions, or use
the WORDS tab. The WORDS tab also holds snippets (say "my email address", get
the address) and imports or exports words as JSON or CSV. See
[docs/WORDS_FILES.md](docs/WORDS_FILES.md).

The first-run default is Parakeet Ultra, a post-trained Parakeet TDT v3 with
the same 25 European languages and speed and fewer errors (model by moondream,
Core ML build by FluidInference, CC-BY-4.0). Parakeet TDT v3 stays in the list,
and anyone already on it keeps it until they pick Ultra in Models. The model
picker also exposes these optional local Whisper models:

- `Large v3 Turbo`: recommended high-quality multilingual Whisper option.
- `Large v3`: maximum accuracy, slower.
- `Medium`: balanced fallback for older Macs.
- `Small`: fast, less accurate.
- `Base` / `Tiny`: lightweight multilingual fallbacks.
- `Medium English`, `Small English`, `Base English`, `Tiny English`: English-only models that automatically set language to `en` when selected.

Models must exist in `~/Library/Application Support/YappYapp/models/` before they will show as ready.

Install every model exposed by the picker:

```bash
./scripts/install_model.sh --all
```

Check the local environment before debugging a new install:

```bash
./scripts/doctor.sh
```

For GitHub issues, use a sanitized support report instead of pasting app
logs, config files, transcripts, or audio. In the app, open SETUP, scroll to
HELP and click COPY REPORT (or SAVE AS FILE). The same section lists
recent YappYapp crash reports with a REVEAL button. From a source checkout:

```bash
./scripts/support_report.sh
```

Simulate first launch without touching your
real `~/Library/Application Support`:

```bash
./scripts/clean_install_smoke.sh
./scripts/source_install_smoke.sh
```

After packaging, smoke-test the built app executable against isolated support
data:

```bash
./scripts/package_app.sh
./scripts/launch_smoke.sh
```

For release candidates, also test the macOS LaunchServices path used by
double-click/open:

```bash
./scripts/launchservices_smoke.sh
```

Generate a manual QA evidence report before testing the release candidate on a
clean account or second Mac:

```bash
./scripts/manual_qa_report.sh --run-launchservices-smoke > dist/manual-qa-report.md
```

Back up local config, glossary, and pet stats before reinstalling or switching
machines:

```bash
./scripts/export_settings.sh ~/Desktop/yappyapp-settings.zip
./scripts/import_settings.sh ~/Desktop/yappyapp-settings.zip       # dry run
./scripts/import_settings.sh --apply ~/Desktop/yappyapp-settings.zip
```

Reset local app data after reviewing the exact dry-run targets:

```bash
./scripts/reset_app_data.sh
./scripts/reset_app_data.sh --apply --backup ~/Desktop/yappyapp-before-reset.zip
```

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md), [ROADMAP.md](ROADMAP.md), [SECURITY.md](SECURITY.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [docs/INSTALL.md](docs/INSTALL.md), [docs/GATEKEEPER.md](docs/GATEKEEPER.md), [docs/MODEL_DISTRIBUTION.md](docs/MODEL_DISTRIBUTION.md), and [docs/RELEASE_PROVENANCE.json](docs/RELEASE_PROVENANCE.json). Release candidates should follow [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Who built this

YappYapp is built by Miguel Torrez:
[LinkedIn](https://www.linkedin.com/in/miguel-torrez),
[YouTube](https://www.youtube.com/@migueltorrezai),
[GitHub](https://github.com/migueltorrezd).

### Contributors

Contributions are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). Everyone
whose pull request is merged is listed here.

- Miguel Torrez ([@migueltorrezd](https://github.com/migueltorrezd))

## License

YappYapp is released under the [MIT License](LICENSE). Model weights and third-party dependencies keep their own licenses and notices; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Packaging

Build a local `.app` bundle:

```bash
./scripts/package_app.sh
open dist/YappYapp.app
```

For team distribution, sign and notarize the generated app or wrap it in a signed `.pkg` for MDM deployment. See [docs/PACKAGING.md](docs/PACKAGING.md).

## Configuration

Default `config.json`:

```json
{
  "additionalPrompt": "Company vocabulary and exact spellings may include product names, client names, internal tools, acronyms, and multilingual business terminology.",
  "allowModelDownloads": true,
  "keepModelWarm": true,
  "language": "auto",
  "maxRecordingSeconds": 300,
  "modelPath": "parakeet://ultra",
  "numberStyle": "spoken",
  "autoPaste": true,
  "escCancelsRecording": true,
  "pasteWhenFocusIsUnclear": true,
  "quietVoiceBoost": true,
  "removeFillerWords": false,
  "restoreClipboardAfterPaste": true,
  "showTextInNotifications": false,
  "translateTarget": "off",
  "translationModel": "hy-mt2-1.8b",
  "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli"
}
```

`translateTarget` is `off` or one of `en`, `fr`, `es`, `nl`, `de`, `pt`, `it`, `ja`, `zh`, `ko`. `translationModel` is `hy-mt2-1.8b`, `hy-mt2-7b` or `whisper` (English only, with a Whisper model; otherwise the 1.8B stands in). Older configs with `translateToEnglish: true` migrate to `translateTarget: "en"`, through Whisper when a Whisper model is active and through Hy-MT2 1.8B otherwise. YappYapp still writes `translateToEnglish` (true only on the Whisper route) so an older build reading the file keeps working.

`numberStyle` is `spoken` (the default), `digits` or `words`; an unknown value reads as `spoken`.

`appLanguage` sets the interface language: `system` (the default, follows the Mac), `en`, `fr`, `es` or `nl`. It is separate from `language`, which is the dictation language.

Use `language: "auto"` for multilingual teams. If a user mostly dictates in one language, setting `fr`, `en`, `es`, or another Whisper language code usually improves speed and accuracy.

Set `allowModelDownloads` to `false` for air-gapped or managed installs. YappYapp will then refuse in-app Whisper and pinned Parakeet downloads, treat Parakeet caches without a valid YappYapp integrity manifest as not ready, and show manual-install guidance in the setup checklist and Models tab; install models ahead of time instead. FluidAudio's own network path is forced offline in every configuration and only loads verified local caches. See [docs/MODEL_DISTRIBUTION.md](docs/MODEL_DISTRIBUTION.md) for the release policy. To force this and other settings fleet-wide through MDM, see [docs/MANAGED_INSTALLS.md](docs/MANAGED_INSTALLS.md).

Browsers, terminals, and common Electron/WebView apps like Slack, WhatsApp, Notion, VS Code, and Cursor use a real Cmd+V paste event so their editor state receives the transcript. For other difficult apps, keep `pasteWhenFocusIsUnclear` ("Paste even without a text field") enabled. `autoPaste` ("Auto-paste into the active app") is the master switch: off means every dictation is copied only. If paste is unreliable, disable clipboard restore so the transcript remains available for manual paste.

## Project status

The current local release gate covers the standalone Swift Testing target, the
built-in 17,000+ assertion integration/UI suite, synthesized-speech E2E,
clean/source install defaults, offline managed config, package and
LaunchServices startup, dependency notices, provenance, source policies, DMG
contents, and artifact checksums. See
[docs/OPEN_SOURCE_AUDIT.md](docs/OPEN_SOURCE_AUDIT.md) for dated verification
evidence and remaining manual/external limits. See [ROADMAP.md](ROADMAP.md) for
the planned distribution path.

0.4.0 (build 6) is the current version: see
[docs/RELEASE_NOTES_0.4.0.md](docs/RELEASE_NOTES_0.4.0.md), and run
[docs/MANUAL_QA_0.4.0.md](docs/MANUAL_QA_0.4.0.md) with the real app before
publishing it.

For a non-destructive pet/wardrobe debugging session, enable the explicit
environment flag before launching YappYapp:

```bash
launchctl setenv YAPPYAPP_DEBUG_UNLOCKS 1
open -n dist/YappYapp.app
```

Every pet is presented unlocked and hatched, and every accessory is selectable,
without rewriting `stats.json` or bypassing production progression rules. End
the debug override with `launchctl unsetenv YAPPYAPP_DEBUG_UNLOCKS` and relaunch.

Before distributing any build, complete clean-user manual QA and review third-party/model notices for the exact artifacts being shipped. Release DMGs are Developer ID signed and notarized; an ad-hoc or self-signed build still needs the one-time first-open step (see [docs/GATEKEEPER.md](docs/GATEKEEPER.md)). <!-- GATEKEEPER-DOC-M2 -->

## Network use

Dictation audio and transcripts never leave the Mac. These are the only
connections YappYapp makes:

- **Update checks (Sparkle).** Packaged builds check
  `https://raw.githubusercontent.com/migueltorrezd/yappyapp-releases/main/appcast.xml`
  once a day. The request carries the app version, nothing about you or your
  dictations. Turn it off with "Check for updates daily" in Setup
  (`automaticUpdateChecks: false` in `config.json`). Source builds never check.
- **Update downloads.** When you accept an update, the new DMG comes from
  `github.com/migueltorrezd/yappyapp-releases` and Sparkle verifies its EdDSA
  signature before installing.
- **Model downloads.** Whisper models, Parakeet models, Qwen3-ASR models and
  the optional LLM cleanup model come from pinned `huggingface.co` revisions,
  only when you pick one, and are checksum-verified. `allowModelDownloads: false` blocks them all.
  The cleanup model is fetched only when the bundled llama.cpp runtime is
  present, and the runtime itself is built without network model downloads.
- **Local only.** The warm Whisper engine and the warm cleanup, translation
  and Qwen3-ASR `llama-server` processes listen on `127.0.0.1` behind a random
  port and path; they are not reachable from other machines. Qwen3-ASR
  recordings travel to its server only in the body of that loopback request.
- **Developer links.** Setup > HELP has YOUTUBE and LINKEDIN buttons. They open
  the page in your default browser only when you click one; YappYapp itself
  never contacts those sites and makes no background requests for them.

## Privacy

- Audio, transcripts and your words stay on this Mac. Nothing is uploaded.
- Learn from my fixes reads only the text YappYapp just pasted, in the field it
  pasted into, for at most 20 seconds after the paste. It skips terminals,
  password fields and secure input. Only the pasted stretch is compared;
  nothing it reads is logged or saved. Only a learned word is saved (to your
  WORDS), plus the spelling of a learned word you undo or delete, so it is
  never learned again. Turn it off in Setup > Dictation > Learn from my fixes;
  an IT admin can lock it with the `learnFromFixes` key
  ([docs/MANAGED_INSTALLS.md](docs/MANAGED_INSTALLS.md)).
- Your words reach the speech and cleanup helpers over stdin or a loopback
  request body, never on a command line.

## Compliance posture

YappYapp does not need a network entitlement for runtime transcription after a selected model is installed. Setup scripts can download source/model files; YappYapp fetches Parakeet files from pinned Hugging Face revisions and verifies them before activation unless `allowModelDownloads` is off. The app deletes temporary WAV files after transcription, deletes the in-flight one on quit, and sweeps leftover `yappyapp-*` temp files at launch.

Clipboard managers can retain copied text. YappYapp always puts the previous clipboard back after a paste (the old `restoreClipboardAfterPaste` key is still written as `true` and any stored value is ignored). For sensitive environments, consider disabling third-party clipboard history tools on managed machines.
