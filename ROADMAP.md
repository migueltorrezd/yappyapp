# YappYapp Roadmap

YappYapp is a local-only macOS dictation app: a private, fast, and charming
alternative to cloud dictation tools. Your voice never leaves the Mac, there is
no subscription, no transcript history is written to disk, and a pixel pet keeps
you company.

This roadmap is ordered by execution priority, not by date. The guiding
principle is foundation before funnel before features. First a runtime that never
crashes or wedges and never lies about what it did. Then a first run that
reliably earns the permissions it needs. Then the release. Then the value-adds.

## Execution order at a glance

1. Stability and correctness (do not crash, do not wedge, do not lie)
2. First-run that works (Gatekeeper, microphone, Accessibility)
3. First public release
4. Daily-driver parity (rebindable hotkey, push-to-talk, per-app profiles)
5. On-device AI cleanup (the differentiator)

Three ongoing tracks run alongside these: personality and retention,
contributor-friendly internals, and managed/offline installs.

## Current status

- Local beta: usable, with auto-paste working once Accessibility is granted.
- Source install: documented and smoke-tested.
- Packaged app: builds locally, bundles `whisper-cli` and `whisper-server`, and
  passes the local release gate with ad-hoc signing.
- Privacy posture: no cloud transcription, no transcript history on disk, and
  temporary audio is cleaned up after dictation.
- Model posture: public builds do not commit or bundle model weights by default.
  Whisper and Parakeet downloads come from pinned revisions and are verified by
  YappYapp; FluidAudio itself always runs offline.
- One distinctive Brutalist design system shared by the control window, menu-bar popover, and HUD.

## Shipped in 0.4.1 (build 7)

A maintenance release on top of 0.4.0: Sparkle 2.10.0 for the updater,
FluidAudio 0.17.7 for Parakeet (same pinned models), swift-testing 6.4.1 and
current GitHub Actions versions. See `docs/RELEASE_NOTES_0.4.1.md`.

## Shipped in 0.4.0 (build 6)

0.4.0 works through a 2026-10-06 production readiness review (76 findings)
and adds most of its missing features. In short:

- Honest outcomes everywhere: PASTED, SENT?, COPIED ONLY and NOT PASTED on the
  HUD, chip and pet; no dropped transcripts on overlap or app switch; a
  notification with Copy when a dictation does not land.
- First run that works: one-click Parakeet download with live progress, plain
  download errors with RETRY, a mic check, no READY before setup is done, a real
  main menu, and a control window that no longer opens at every login.
- Recording that holds up: one warm session, default-input changes, sleep and
  stalled-capture recovery, no chime in the transcript, multichannel downmix.
- Shortcuts: rebindable, Toggle, Hold or Hybrid, an optional one-key trigger,
  Paste Last, Retry Last and Undo Last, plus Esc with UNDO.
- Cleanup with modes (Verbatim, Clean, Email, List, Notes) on a bundled
  llama.cpp runtime, spoken edit commands, snippets with import and export,
  per-app profiles with a HUD badge, live preview, file transcription.
- Settings repair, MDM managed preferences, a helper-binary policy, a hardened
  local Whisper server, clipboard privacy markers.
- Text size, a focus ring, VoiceOver announcements, and the UI in English,
  French, Spanish and Dutch.
- Release tooling: SDK selection, version-bump guard, publish runbook, cask with
  zap, uninstall docs.

0.4.0 is the first release signed with a Developer ID and notarized by Apple.

Still open after 0.4.0: the public-repo
text edits listed in `docs/RELEASE_CHECKLIST.md`, clean-account manual QA
(`docs/MANUAL_QA_0.4.0.md`), a native-speaker review of the translations,
cleanup prompt tuning on the real model, spoken punctuation, a per-app glossary,
a cleanup command mode, and the iOS companion.

## Milestone 1: Stability and correctness

Goal: the app survives an all-day session across device changes, the shortcut
never dies, and every status it shows is true. Everything else is built on this.
All items below are identified in `docs/OPEN_SOURCE_AUDIT.md`.

Status: all six items are fixed as of 0.4.0. The two partial ones below were
completed by YA-16 (hotkey) and YA-03 plus YA-15 (paste outcome).

- Hotkey never wedges. **Partially fixed, completing in 0.4.0.** A stale
  "pressed" flag is now cleared by checking the physical key state, so the
  shortcut can no longer stay dead until relaunch. The check still swallows
  the first real press after a lost release (YA-16); 0.4.0 tells repeats from
  fresh presses by event time instead.
- Recording is thread-safe. **Fixed.** Writer, converter and session fields
  sit behind a lock. Leftovers are tracked as low-priority items (YA-56) and
  the warm-mic race (YA-04).
- Route-change handling matches the shipped path. **Fixed.** The engine path
  is gone and capture-session observers finish gracefully. Sleep and
  stopped-session handling is tracked separately (YA-21).
- Honest paste outcome. **Partially fixed, completing in 0.4.0.** The status
  text is honest (`pastedBestEffort`, `withheld`), but the HUD and pet still
  celebrate unconfirmed pastes (YA-03) and the "press Cmd+V" advice fails
  after the clipboard restore (YA-15). 0.4.0 makes every surface report what
  actually happened.
- Pet stats are correct. **Fixed.** XP goes only to the unlocked active pet,
  and the journey-streak day math is parse-safe. Travelling west across
  midnight is tracked separately (YA-30).

Every change here keeps the self-test suite green and adds coverage where logic
changes.

## Milestone 2: First-run that works

Goal: a new user on a clean Mac goes from download to working dictation without
guessing. This was the highest adoption risk while releases were not notarized,
because users hit two permission walls back to back.

- Guided first run: first open (a plain double-click for notarized releases
  from 0.4.0 on), then microphone, then Accessibility, each verified live.
- Detect the stale or duplicate Accessibility (TCC) entries left by reinstalls
  and offer a one-click reset-and-regrant.
- A persistent, unmissable banner whenever paste permission is missing, so the
  app never silently degrades to copy-only.
- Cheap wins that are also the pitch: a "nothing left this Mac" privacy badge and
  a "time saved" stat on the recap card.

Depends on Milestone 1's honest paste-state. Must be verified with real manual QA
on a clean account, because automated tests cannot see the permission reality.

## Milestone 3: First public release

Goal: a release artifact that developers can build from source and that normal
users can download, verify, and open. Cut this once the app does not crash, does
not wedge, does not lie, and onboards cleanly. The repository can go public
earlier; the downloadable release is the gated artifact.

Developer ID signing and notarization arrived with 0.4.0
(`scripts/notarization_preflight.sh`, `scripts/notarize.sh`). Source builds and
ad-hoc candidates keep the right-click Open guidance.

Done:

- MIT license and third-party notices.
- Install, model-distribution, packaging, release-checklist, and audit docs.
- Built-in self-tests plus synthesized-speech end-to-end coverage.
- Source-install, clean-install, offline-managed, settings-backup, reset, launch,
  LaunchServices, ignore-policy, model-weight, privacy-artifact, provenance, and
  support-report checks.
- Ad-hoc DMG and app-zip artifacts with checksums, and install docs explaining
  the right-click Open path for non-notarized builds.
- Sanitized support report for GitHub issues, in the app (SETUP, SUPPORT, with
  recent crash reports) and as scripts/support_report.sh.
- Mic check in guided setup and SETUP: a live level meter that tells whispering
  users whether Quiet Voice Boost will help. Nothing is saved or transcribed.

Remaining:

- Complete clean-account manual QA on a fresh macOS user or second Mac.
- Fill the target-app paste matrix from real apps, not assumptions.
- Confirm first-run microphone and Accessibility prompts on a machine that has
  never granted YappYapp permissions.

## Milestone 4: Daily-driver parity

Goal: make YappYapp a credible everyday tool. Low-risk table stakes that ship
quickly after the first release.

- Rebindable global hotkey. Shipped in 0.4.0 (Setup > Shortcuts), with
  warnings for combos that collide with Alfred, Raycast or accent typing.
- Push-to-talk (hold to dictate) alongside the toggle. Shipped in 0.4.0 as
  Hold and Hybrid modes, plus an optional one-key trigger.
- Paste Last, Retry Last and Undo Last, spoken edit commands (new line, new
  paragraph, scratch that) and snippets. Shipped in 0.4.0. Spoken punctuation
  ("period", "comma") is left out on purpose: the words are too common.
- Per-app profiles: language, cleanup, paste mode and model by the app a
  dictation starts in, with a HUD badge for the active language and model.
  Shipped; per-app glossary is still open.
- Localized UI (YA-42): English, French, Spanish (Latin American) and Dutch,
  following the system language with an in-app App language override.
  Shipped; the tables still need a native-speaker review pass.

## Milestone 5: On-device AI cleanup

Goal: the post-processing that wins switchers, kept fully local to protect the
privacy posture. This is the headline feature, but it is a large effort with real
design forks, so it lands on a mature, stable base rather than gating the first
release.

- Optional cleanup that tidies rambling, smart-removes filler, and formats as
  email, list, or notes.
- Strictly on-device (MLX or llama.cpp with a small instruct model). No network
  at runtime, ever.
- Paired with perceived-latency feedback so the extra inference time feels
  instant.
- Open design questions: model choice and size, bundle versus download, and
  cleanup mode versus a command mode.
- Status (2026-10-16): first cut landed. The llama.cpp runtime ships in the
  app (static, Metal, pinned release); the Qwen 2.5 1.5B model downloads on
  demand with progress and a cancel. Modes: Verbatim, Clean, Email, List,
  Notes. Spoken corrections ("no wait, I meant") are resolved by rule before
  the model runs, every rewrite passes a word-overlap, language and length
  guard, and a hard timeout returns the raw text. Per-app profiles can pick
  any mode. Still open: a command mode.
- Done: live preview text in the HUD while recording (opt-in, Parakeet only,
  memory only, never pasted).
- Done: file transcription from the status menu or by dropping a file on the
  MIC tab (WAV, M4A, MP3, AIFF, CAF, MP4, MOV). The text is copied and kept in
  the in-memory history. The iOS companion stays out of scope.

## Ongoing tracks

### Personality and retention

The pixel pet is a retention hook the cloud apps do not have. Expand it with
mic-reactive moods, milestone celebrations, a whisper streak, seasonal wardrobe,
and recap-card flair. Low risk, high shareability, good filler between
milestones.

### Contributor-friendly internals

- Continue shrinking `AppDelegate.swift` by extracting coordinators for recording
  session lifecycle, paste-target tracking, notifications, and launch-at-login.
- Continue extracting reusable Brutalist primitives from
  `BrutalistPopoverView.swift` without flattening its visual character.
- Keep every extraction covered by deterministic self-tests.

### Managed and offline installs

- `allowModelDownloads` disables in-app Whisper downloads and FluidAudio Parakeet
  downloads; an offline managed-config smoke test verifies the posture.
- Settings export/import and reset scripts avoid copying models, transcripts,
  audio, logs, and temporary files.
- Document a concrete MDM/package recipe once the distribution channel is chosen.

## Not planned

- Cloud transcription as a default feature.
- Runtime API keys for transcription.
- Persistent transcript history on disk.
- Bundled model weights in the default public release.
- Pasting into secure or password fields.

## Release gates

Before a public source or ad-hoc beta, the following must be true:

- `./scripts/verify_release.sh` passes.
- `./scripts/check_hf_model_metadata.sh` passes and any upstream license or
  revision changes are reviewed.
- `./scripts/check_docs_links.sh` passes.
- `dist/manual-qa-report.md` is completed on a clean account or second Mac,
  including the first-run permission flow and the target-app paste matrix.
- Release notes include runtime and model revisions, checksum posture,
  non-notarized Gatekeeper guidance, privacy and permission notes, known
  limitations, and verification evidence.
