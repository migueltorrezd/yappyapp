# Release Readiness Audit

Date: 2026-07-15
Release: YappYapp 0.3.1 (build 4)
Bundle identifier: `app.yappyapp.YappYapp`

## Verdict

The current local tree is release-gate clean for a signed local or ad-hoc beta.
The complete verifier passed on macOS 26.5.1 on Apple Silicon, including the
debug suite, synthesized-speech E2E, clean and managed installs, release
packaging, executable and LaunchServices startup, dependency notices,
supply-chain policy, DMG and ZIP extraction, signatures, and artifact
checksums.

This audit predates the public source repository and does not claim a
notarized Developer ID distribution. Before a broad end-user release, complete
visible first-run QA on a clean macOS account and choose a public distribution
and notarization policy.

## Final Verification Evidence

Command:

```bash
./scripts/verify_release.sh
```

Result: passed.

- Built-in debug suite: 7,882 assertions passed.
- Synthesized-speech E2E: passed with `ggml-tiny.en.bin`.
- Final doctor: 0 failures and 0 warnings.
- Clean first launch, idempotence, legacy migration, and mixed-folder merge:
  passed.
- Source install, managed/offline config, settings backup/import, and app-data
  reset smokes: passed.
- Packaged executable launch and macOS LaunchServices launch: passed.
- Release executable excludes all test-only CLI surfaces. The two supported
  read-only diagnostics remain, while `--launch-smoke` is verified
  behaviorally through both mandatory launch smokes.
- Packaged notices, source ignore policy, documentation links, model catalog,
  no-bundled-model policy, and privacy artifact policy: passed.
- Runtime network policy and release provenance: passed.
- Live Hugging Face metadata for Whisper, four Parakeet repositories, and the
  optional Qwen cleanup model matched the pinned public/non-gated records.
- App, mounted-DMG app, and ZIP-extracted app signatures: passed deep/strict
  verification.
- DMG layout/content and release artifact extraction: passed.
- Support-report smoke: passed.

Expected fixture warnings appeared earlier in the run only:

- The source-install fixture intentionally has no local Whisper weights because
  Parakeet is the first-run default and downloads are allowed.
- The managed-install fixture intentionally uses a custom Whisper filename with
  no registered checksum to exercise the manual-verification warning.

Neither warning was present in the final doctor.

## Signed Artifacts

The app was signed with the local stable identity `YappYapp Dev`, with
hardened runtime enabled. This preserves the local Accessibility grant across
rebuilds but is not a Developer ID or notarization claim.

```text
739fac7a2b4e8277f32c5e87cf24e2b2c8fdaed09bf85b1d585c594249502570  YappYapp.dmg
c8b1b9952ae7e9a64874d614fa6ce7783b0c7856d1e44a29efb43777c31388c5  YappYapp.app.zip
```

Canonical checksum file: `dist/checksums.txt`.

## Security and Supply Chain

- Transcription is local after the selected model is installed. Dictation audio
  and transcript text are not sent to a cloud transcription service.
- Temporary WAV files are deleted after success or failure. Transcript history
  remains in memory. App-created support data uses owner-only directories and
  files.
- Whisper model downloads use the immutable Hugging Face revision recorded in
  `docs/RELEASE_PROVENANCE.json` and verify registered SHA-1 values.
  `scripts/install_model.sh` rejects unsupported models before network access.
- `scripts/bootstrap_whisper_cpp.sh` builds only the pinned runtime revision
  and fails closed if provenance is missing or malformed.
- YappYapp owns the Parakeet download path. It uses fixed
  `https://huggingface.co` tree and resolve endpoints at exact revisions,
  rejects unsafe paths, verifies sizes and LFS SHA-256 or Git blob SHA-1, and
  writes an owner-only `.yappyapp-integrity-v1.json` manifest.
- The verified Parakeet repositories are public and non-gated. The downloader
  does not honor environment-controlled registry origins or attach ambient
  Hugging Face credentials.
- FluidAudio is forced offline and only loads a cache after YappYapp verifies
  it. Recording also refuses an unverified Parakeet cache.
- Warm Whisper inference binds to `127.0.0.1`. Per-dictation glossary context
  travels in the private multipart request, not process arguments. Server output
  is discarded by default; opt-in diagnostics are truncated and owner-only.
- The production executable excludes the self-test harness and content-printing
  smoke commands.
- Default release artifacts contain no model weights, recorded audio, transcript
  artifacts, or network entitlements.
- Full licenses for whisper.cpp, FluidAudio and its third-party notices, and
  Sparkle ship inside the app, DMG, and ZIP.

## Product and Accessibility Quality

- Parakeet TDT v3 is the first-run default. Every app surface uses the single
  Brutalist design system; legacy `appearance` keys are ignored when decoding.
- The app exposes both a menu-bar popover and a 440 by 596 floating control
  window, plus recording/transcription HUDs.
- Readiness checks poll every 2 seconds during guided setup and every 60 seconds
  after completion; explicit changes and window presentation refresh directly.
- UI rendering tests cover all tabs and states, long multilingual
  content, and all pet forms.
- Reduce Motion disables decorative motion while preserving state feedback.
- Default-mode idle sampling measured 0.0 percent CPU in the dedicated
  performance pass. The opt-in warm-microphone mode intentionally uses more.
- Accessibility guards cover microphone and paste permission recovery, secure
  fields, native AX insertion, browser/terminal/WebView paste, clipboard
  fallback, and stale permission state.

## Brutalist Quality Score

The pre-refactor Brutal implementation scored 13/20: Accessibility 2/4,
Performance 4/4, Responsive Design 2/4, Theming 2/4, and Anti-Patterns 3/4.
The current Brutal-only implementation scores 20/20:

| Dimension | Score | Verification |
|---|---:|---|
| Accessibility | 4/4 | Semantic control roles, labels, values, selection and disabled state, keyboard disclosure, visible focus, expanded targets, and 11 automated AA text-role contrast pairs. |
| Performance | 4/4 | Five settled idle samples at 0.0 percent CPU, no dormant pet/readiness/recording stacks, bounded polling, and Reduce Motion coverage. |
| Responsive Design | 4/4 | Shipped default geometry is preserved while typography scales, every tab can scroll, functional copy wraps, and Accessibility5 multilingual rendering passes at 440 by 596. |
| Theming | 4/4 | One canonical semantic Brutalist system owns palette, typography, geometry, focus, fields, buttons, and waveform behavior; no appearance switch or persisted theme key remains. |
| Anti-Patterns | 4/4 | No alternate Glass UI, blur, material, gradient, soft shadow, bouncy transition, nested model actions, exact neutral shortcut, or inaccessible custom-toggle representation remains. |
| **Total** | **20/20** | **Five verified 4/4 dimensions.** |

The fixed 440 by 596 outer viewport is intentional for this macOS menu-bar
utility. Responsiveness is evaluated as content resilience, scalable text,
keyboard reachability, wrapping, and scrolling inside that canonical viewport.

## Remaining Manual and External Gates

1. Run visible first-launch QA on a clean macOS user account:
   microphone prompt, Accessibility grant and regrant, menu-bar interaction,
   control-window reopen, first Parakeet download, and offline recovery.
2. Run the target-app paste matrix in Safari/Chrome, Terminal, Slack, Notion,
   VS Code/Cursor, and representative native text fields.
3. Run `./scripts/route_change_test.sh --run` with two real input devices. The
   automated verifier lists devices but intentionally does not change the system
   default microphone.
4. Before public binary distribution, choose Developer ID signing/notarization
   or keep the documented non-notarized first-open flow.
5. Before announcing source availability, establish and audit the actual public
   repository surface and history for secrets and provenance.
6. Re-run the full verifier and live model-card metadata check for every release
   candidate. Artifact checksums and signatures are release-specific.

## Canonical Commands

```bash
./scripts/run_tests.sh
./scripts/verify_release.sh
./scripts/check_hf_model_metadata.sh
./scripts/check_provenance.sh
./scripts/check_network_policy.sh
./scripts/doctor.sh
./scripts/route_change_test.sh --list-devices
./scripts/route_change_test.sh --run
./scripts/notarization_preflight.sh
./scripts/manual_qa_report.sh --run-launchservices-smoke > dist/manual-qa-report.md
```
