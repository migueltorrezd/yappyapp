# Architecture

## Pipeline

```text
⌥ space by default, rebindable, toggle/hold/hybrid (esc cancels)
  -> start sound + bottom HUD with live microphone waveform and elapsed timer
  -> AVCaptureSession on the chosen input device (warm or cold), downmixed and converted to 16 kHz mono WAV
  -> per-app profile resolved from the app in front at start (language, model, cleanup, paste)
  -> selected local engine
     -> Parakeet Ultra in-process through FluidAudio (first-run default), or
     -> warm whisper-server (random localhost port, secret path) with whisper-cli fallback, or
     -> Qwen3-ASR (52 languages): warm llama-server with --mmproj (audio as base64 input_audio in the
        loopback request body) with one-shot llama-mtmd-cli fallback; parts of at most 240 s
  -> Whisper-only glossary prompt bias
  -> deterministic glossary correction
  -> Whisper output guard (drops silence hallucinations and prompt echoes; also run on Qwen3-ASR output)
  -> optional LLM cleanup mode (rule-based self-corrections, then llama.cpp, accept() guard, raw on failure)
  -> spoken edit commands ("new line", "scratch that", whole clauses only)
  -> number style (NUMBERS: AS SPOKEN, DIGITS or WORDS; NumberForms, EN/FR/ES/NL, snippet phrases and
     glossary words protected)
  -> snippet expansion (spoken phrase -> stored text, exact match)
  -> optional translation (TRANSLATE TO): Whisper -tr for English on a Whisper model, else a pinned Hy-MT2 GGUF
     through the warm translation llama-server, else one-shot llama-completion (prompt on stdin), both behind
     TranslationEngine with the model's Jinja chat template and greedy sampling, untranslated on failure
  -> stop sound + transcribing HUD
  -> secure-input check (never types into password fields)
  -> DictationDeliveryCoordinator: queue behind a paste in flight, copy if superseded or the app changed
  -> direct AX insertion when supported (captured target re-resolved after activation)
  -> NSPasteboard + Cmd-V fallback
  -> manual copy fallback from Last transcript
  -> temporary audio deletion (kept for Retry only after a failure; swept at launch)
```

## Local speech engines

`ParakeetTranscriber` is the first-run path. It loads the selected CoreML model
through FluidAudio and keeps it warm in-process. Parakeet Ultra
(`parakeet://ultra`, FluidAudio `AsrModelVersion.ultra`, 0.17.3 or newer) is the
default; it is a post-trained TDT v3 with the same file contract, so live
preview, warm mode, memory policy and language detection treat it exactly like
v3. The Models tab also exposes Parakeet TDT v3 and the other Parakeet variants
and local Whisper models; a saved v3 choice is never switched automatically.
Only YappYapp's pinned, digest-verifying downloader may fetch Parakeet files.
FluidAudio is forced offline, and both recording and `AsrModels.load` require a
cache with a valid YappYapp integrity manifest.

### Qwen3-ASR

`Qwen3ASRTranscriber` runs the Qwen3-ASR models (Apache-2.0, 52 languages and
dialects) through the bundled llama.cpp runtime. Each model is two pinned
GGUFs from `ggml-org/Qwen3-ASR-*-GGUF`: the language model and its audio
projector (`qwen3a`, supported by the pinned llama.cpp release), Q8_0, both
SHA-256 verified by `Qwen3ASRModelStore` with the same stamps as the
translation models, and fetched one after the other by
`Qwen3ASRDownloadCoordinator` through `CleanupModelDownloader`. Model paths in
`config.json` are `qwen3asr://0.6b` and `qwen3asr://1.7b`.

A third `LlamaServerController` instance (`.speech`) keeps the selected size
warm (`--mmproj`, 8192-token context) only while Qwen3-ASR is the speech
engine, its files are verified, keep-warm is on and memory pressure is not
critical; a warm-up request with half a second of silence compiles the audio
kernels. Each dictation is one chat request in the model card's shape: the
glossary terms as the system turn (context), the recording alone as an
`input_audio` part of the user turn, and, when the dictation language is not
AUTO, the assistant prefill `language <Name><asr_text>` so the model writes the
transcript only. The context is the WORDS spellings, comma separated, at most
40, with chat markup stripped (`Qwen3ASRPrompt.context`), as the official
`qwen_asr` package builds its system message. Not ready, another size loaded or
no server: the one-shot `llama-mtmd-cli` runs with the same chat. Its prompt
(context, audio marker, prefill, split by a fixed separator) comes from stdin
(`-f /dev/stdin`) and a fixed Jinja template in argv rebuilds the system, user
and assistant turns, so argv holds only file paths, fixed flags and the
template, never a word from the glossary. Measured 2026-10-18 with the pinned
0.6B Q8_0 on five `say` clips holding 12 unusual names (EN, FR, ES): 3 of 12
spelled right without the words, 10 of 12 with them, the same one-shot and
warm, at no measurable cost (about 0.6 s one-shot, 0.1 s warm, either way). A server timeout replaces the
busy server and keeps the audio for a retry, like Whisper. The reply's
`language X<asr_text>` header is stripped, `language None` means no speech,
runaway repetitions collapse like in the official package, and the Whisper
output guard drops silence hallucinations and glossary echoes. Recordings
longer than 240 s are cut at quiet moments with the FILES chunker so each part
fits the context; timeouts scale per part (`TranscriptionTimeouts.qwen3ASRWatchdog`).

### Warm Whisper server

`WhisperServerController` keeps a `whisper-server` process running on
127.0.0.1. Each launch picks a free random port and a random `--request-path`
secret, so no web page or other local process can guess the routes. Its launch
arguments contain the runtime path, selected model, language, translation mode,
quiet-voice decoding flags, port and secret. They never contain the glossary or
additional prompt: each dictation sends the current prompt in the private
localhost multipart request to `<secret>/inference`. Prompt-only changes
therefore do not restart the server.

Readiness requires both a 200 from `<secret>/health` and the port's listener
being the child process the controller launched, so an orphaned or squatting
listener is never trusted. Servers stranded by a crashed session (our exact
binary, re-parented to launchd) are terminated before a launch. A server that
exits on its own is relaunched with exponential backoff (1s doubling to 60s,
reset after two healthy minutes).

`scripts/bootstrap_whisper_cpp.sh` applies `scripts/patches/*.patch`
idempotently on top of the pinned whisper.cpp revision. The server patch drops
the `Access-Control-Allow-Origin: *` headers, the `/load` route and static file
serving, and refuses any request with a browser `Origin` header. The CLI patch
adds `--prompt-file`.

Request timeouts scale with the audio length and beam search
(`TranscriptionTimeouts`), and so does the app watchdog. Only a server that
cannot be reached, or that refuses a request outright, hands the dictation to
`whisper-cli`. A timeout instead replaces the busy server and keeps the audio
for a retry ("Retry Last Dictation" in the menu bar icon's menu, or RETRY
on the HUD and MIC tab). Retry-last also works after a delivered dictation:
`LastRecordingMemory` keeps the newest recording's WAV bytes in memory and a
retry writes them to a private temp WAV for that one run. The cold CLI
reads the prompt from an owner-only `--prompt-file` when the binary supports it
(YappYapp's patched build) and otherwise runs without a prompt, so private
vocabulary never reaches `ps`. Whisper output that is only a known silence
hallucination on a near-silent recording, an echo of the prompt, or a
non-speech tag is dropped with "No speech heard."

Server output goes to the null device by
default because it can echo private vocabulary. Setting
`YAPPYAPP_WHISPER_SERVER_LOG=1` opts into a truncated, owner-only
`~/Library/Application Support/YappYapp/server.log` for diagnostics. Disabling
"Keep the model loaded" (Setup > Speed) off stops the server and frees the RAM.

## UI surfaces

- Menu bar item (icon only): toggles an NSPopover anchored to the top of the screen.
- Control window: a 440 x 596 window at the normal window level presents the same controls through `showControlWindow()`. It opens on its own while setup is incomplete and on a manual launch or reopen, never on a login launch once setup is done (`ControlWindowLaunchPolicy`). A minimal main menu (`MainMenuBuilder`) gives it the standard Edit and Window shortcuts.
- Popover: five tabs (Home, Models, Words, Pet, Settings) in one Brutalist design system. Home holds the record button, live waveform, setup checklist, and last transcript. Settings auto-save with a short debounce. The Setup tab lists its sections in `SetupSection` order and draws every control from `BrutalSetupControls` (segmented choice, dropdown, switch, shortcut field, slider, action button, disclosure) with type from the `BrutalTextStyle` roles.
- Bottom HUD: borderless click-through capsule shown only while recording/transcribing, with a live level-driven waveform and the ⌥ space keycaps.
- Live preview (opt-in, SETUP > INDICATOR AND SOUND, Parakeet only): while recording, a one-line strip above the HUD bar shows the last ~60 characters heard. `RecordingController.liveSampleTap` copies post-chime 16 kHz samples into a 10-second in-memory ring (`LivePreviewSampleBuffer`). A 1-second main-thread timer in `LivePreviewController` decodes the window through `ParakeetTranscriber.transcribePreview`, skipping a tick while a decode is in flight, when no new audio arrived, or on silence. The preview never loads a model by itself, never waits behind a dictation (it skips when the decoder is busy), is never pasted, and stops the moment recording ends; a late result is dropped by a generation check. Nothing is written to disk.
- File transcription: "Transcribe Audio File..." in the status menu, CHOOSE FILE on the FILES tab, or a file dropped on the FILES or MIC tab (either way the window switches to FILES). `FileTranscriptionCoordinator` runs one job at a time: `AudioFileConverter` (AVAssetReader, every track and channel mixed down) writes a 16 kHz mono WAV into a private `yappyapp-file-<uuid>` temp folder, `FileTranscriptionChunker` cuts it into ~60-second parts at the quietest point before each mark, and each part goes through the same `transcribe` path as a dictation (glossary, filler removal, Whisper output guard), then the optional LLM cleanup. Progress and CANCEL show on the FILES tab. The result goes only to the FILES results (in memory, with COPY and SAVE as .txt), never pasted. FILES is kept apart from MIC: a file job never writes the dictation history, `lastTranscript`, PASTE LAST, RETRY, undo, stats, the pet, the indicator, the MIC status line or the clipboard; COPY on a result row is the only way its text reaches the clipboard. The temp folder is deleted when the job ends, on quit, or by the launch sweep.
- Parakeet decodes take turns on the one `AsrManager` (FIFO inside `ParakeetTranscriber`), so a dictation waits for at most one preview decode or file part.
- Readiness polls every 2 seconds until guided setup completes, then falls back to a 60-second safety poll. Model downloads, explicit settings changes, and opening the control window trigger their own refreshes, so the configured app stays effectively dormant between dictations without leaving setup feedback stale.

The app has one Brutalist visual system. There is no Glass/material mode. The
five tabs are separate view files behind the shared popover shell, while pet
domain state, wardrobe rules, sprites, rendering, and animation are split into
focused files. The control window and popover intentionally share the same
views and fixed 440 x 596 geometry.

## Runtime coordination

`AppDelegate` remains the composition root and transcription pipeline owner,
but it no longer owns every macOS concern directly:

- `AppWindowCoordinator` owns the popover, control window, HUD windows, and
  display-change observers.
- `PermissionCoordinator` owns microphone/Accessibility state, repair timing,
  stale-TCC detection, and guided-setup persistence.
- `PasteTargetCoordinator` tracks the foreground app and resolves safe paste
  targets and fallbacks.
- `RecordingSessionCoordinator` owns session generations, paste gating,
  auto-stop/idle work, and metering timers. Generation checks prevent stale
  transcription or paste callbacks from mutating a newer recording.

Components added in 0.4.0, each in its own file so `AppDelegate` only wires them:

| Area | Types (file) | Job |
|---|---|---|
| Config | `ConfigRecovery`, `ManagedPreferences`, `HelperBinaryPolicy`, `LaunchAtLogin` | Per-key decode and repair from `config.json.last-good`; MDM-forced keys with LOCKED UI; refuse unsafe helper paths; honest login-item status |
| Recording | `AudioCaptureSupport` (`CaptureWatchdog`, `WarmSessionPlanner`, `ChimeTrimmer`, `AudioDownmix`, `DefaultInputDeviceObserver`) | One warm session, stall and sleep recovery, chime trim, multichannel downmix, default-input rebuild |
| Engines | `TranscriptionTimeouts`, `FailedDictationRetry`, `WhisperServerSecurity`, `WhisperOutputGuard`, `WhisperPromptFile`, `ParakeetMemoryPolicy` | Audio-scaled timeouts, keep audio for retry, random port and secret path, hallucination guard, prompt file instead of argv, unload Parakeet for Whisper |
| Delivery | `DictationDeliveryCoordinator`, `DeliveryPolicy`, `DeliveryNotifier`, `PasteboardPrivacy`, `KeyboardLayoutKeyCode`, `SecureInputOwner`, `TempFileSweeper`, `DeliveryTrail` | Honest outcome phases, notifications with Copy (never under `--self-test`), transient and concealed pasteboard markers, layout-aware Cmd+V, temp cleanup, the last 20 deliveries (target, route, outcome, never text) in the Help support report |
| Shortcuts | `ShortcutSettings`, `ShortcutCoordinator`, `ShortcutGestures` (`HotKeyRepeatFilter`), `ShortcutValidation`, `PasteLastController` | Rebindable chords per action, toggle/hold/hybrid, one-key trigger, repeat-versus-fresh-press by event time |
| Commands | `SpokenCommands`, `InsertionUndo`, `RetryLast` | New line, new paragraph, scratch that; exact undo of the last insertion; in-memory retry |
| Cleanup | `CleanupMode`, `CleanupGuards`, `CleanupModelStore`, `CleanupModelDownloader`, `LLMCleaner+Modes`, `LLMCleaner+Run`, `CleanupServer`, `LlamaServerController` | Modes, self-corrections, acceptance guard, verified model download, warm bundled `llama-server` (`LlamaServerController.cleanup`: 127.0.0.1, random port and path, warm-up request at start, restart with backoff, stopped on quit, cleanup off, keep-warm off or critical memory pressure) with the one-shot `llama-completion` as fallback |
| Translation | `Translation` (`TranslationTarget`, `TranslationCatalog`, `TranslationPlan`, `TranslationReadiness`), `Translator` (`TranslationEngine`, `OneShotLlamaTranslationEngine`, `TranslationModelStore`), `TranslationCoordinator`, `TranslationServer` (`TranslationServerPolicy`, `WarmLlamaTranslationEngine`), `TranslationSettingsControl` | Target languages, model choice and Whisper substitution, Hy-MT2 model-card prompt, SHA-256-pinned downloads, translate step with honest fallbacks. A second `LlamaServerController` instance (`.translation`) keeps the chosen Hy-MT2 model warm with the same rules as cleanup (started at launch and when a target is set and its model verified with keep-warm on; stopped on quit, translation off, keep-warm off, critical memory pressure; replaced on a model change); not ready or another model loaded means the one-shot run. The support report shows both server states |
| Qwen3-ASR | `Qwen3ASR` (`Qwen3ASRVariant`, `Qwen3ASRModelStore`, `Qwen3ASRRuntime`, `Qwen3ASRPrompt`, `Qwen3ASRCLI`), `Qwen3ASRServer` (`Qwen3ASRServerPolicy`, `Qwen3ASRTranscriber`, `Qwen3ASRAudioParts`), `Qwen3ASRDownloads` | Third speech engine: pinned two-file downloads, warm `LlamaServerController.speech` with one-shot `llama-mtmd-cli` fallback, model-card prompt and output parsing, long-audio parts. The support report shows the speech server state |
| Model advice | `ModelAdvisor` (`HardwareProfile`, `AppleChip`, pure rules), `HardwareScanner`, `PowerSource`, `ModelScanCard` | SCAN MY MAC: reads sysctl, memory, macOS, free disk and power, recommends one speech, cleanup and translation model from the catalog |
| Features | `AppProfiles`, `NumberStyle`, `NumberForms`, `NumberLexicon`, `Snippets`, `WordsTransfer`, `LivePreview`, `FileTranscription`, `SupportReport`, `MicLevelCheck` | Per-app profiles and HUD badge, number style, snippets and import/export, live preview, file transcription, support report, mic check |
| First run and UI | `FirstRunReadiness`, `FirstRunPresenters`, `MainMenuBuilder`, `TabFeedback`, `PetGamification`, `BrutalAccessibility` (`AccessibilityAnnouncer`, `BrutalTextSize`, focus ring) | Readiness-driven chip and banners, main menu, per-tab feedback, Pet and quests switch, text size and announcements |
| Debug only | `RenderGallery` (`--render-gallery <dir>`) | Offscreen PNGs of every tab and key state for visual QA; refuses to run without a scratch App Support base and is banned from release binaries |

UI-facing coordinators run on the main actor. Swift 6 language mode and complete
concurrency checking are enforced with warnings treated as errors in CI.

## Localization

Every user-facing string goes through `L10n` (`Sources/YappYapp/L10n.swift`).
The English text is the key, so a string missing from a table shows the
English the code already has. Tables live in
`Sources/YappYapp/Resources/<lang>.lproj/Localizable.strings` (plus
`Localizable.stringsdict` for plurals) for `en`, `fr`, `es` and `nl`.
`L10n` finds SwiftPM's resource bundle in `Contents/Resources` of the packaged
app, next to a debug binary, or next to the test bundle; it never uses
`Bundle.module`, whose accessor traps when the bundle is elsewhere.
`package_app.sh` copies that bundle, re-signs it, adds
`CFBundleLocalizations` and per-language `InfoPlist.strings` for the
microphone prompt. `appLanguage` in the config overrides the system language;
the app applies it at launch and on save, rebuilds the main menu and
re-renders the open tab. Tests and CLI flags stay in English.

Rules for new copy: wrap it in `L10n.tr("...")` (or `L10n.plural` for
counts), add the key to all four tables, keep `%@` placeholders, keep the
tokens `⌥ space` and `Option Space` (the app swaps them for the live
shortcut), and keep product names untranslated. The `l10n.*` self-tests fail
on a missing key, a placeholder mismatch, a dash, a label that no longer fits
its fixed width, or a screen that stops rendering. Set
`YAPPYAPP_L10N_SNAPSHOT_DIR` when running `--self-test` to get a PNG of each
key screen per language. `python3 scripts/check_l10n_keys.py` fails when the
code uses an `L10n.tr` or `L10n.plural` key that a table lacks. `YappYapp --l10n-status` prints where a build found
its tables. Support reports and CLI output stay in English for maintainers.

## Model download isolation

`ModelDownloadManager` is the URL-session/Whisper delegate boundary.
`WhisperDownloadCoordinator` owns the cancel, resume-data, restart, and
generation state machine. `ParakeetModelDistribution` resolves only pinned
manifest entries, verifies sizes and digests, and atomically publishes a cache
only after every file is valid. Stale callbacks cannot publish state for a
newer download generation.

The cleanup and translation GGUFs share `CleanupModelDownloader`, which fetches
only the pinned `source` URL it was created with, and the stamp-based
verification in `CleanupModelStore` (SHA-1 for Qwen, SHA-256 from the Hugging
Face LFS metadata for Hy-MT2). `TranslationCoordinator` keeps one downloader
per translation model and never starts one without the llama.cpp runtime or
with `allowModelDownloads` off. `Qwen3ASRDownloadCoordinator` does the same for
the two files of a Qwen3-ASR model (SHA-256 per file) and reports one
byte-weighted progress on the model's row.

## Why keep whisper.cpp

`whisper.cpp` remains a practical local alternative and compatibility path:

- Runs fully locally.
- Has mature Apple Silicon acceleration paths.
- Can be called from a small Swift app without bundling Python.
- Works with OpenAI Whisper model weights.
- Leaves a path to a direct C API integration later.

The Whisper path calls `whisper-cli` as a subprocess because it is easy to
package and audit. Parakeet runs in-process through FluidAudio and is the
default path for new installs.

## Glossary design

Whisper prompts are context bias, not hard constraints. YappYapp therefore uses these layers:

1. Prompt biasing: canonical glossary terms are passed to Whisper as its
   prompt and to Qwen3-ASR as its context (Parakeet takes no prompt).
2. Deterministic correction (`Glossary.applyingCorrections`): known "sounds
   like" variants are replaced after transcription, then
   `GlossaryNearMiss` writes close misses of a word the user's way even with
   cleanup off. It only touches a transcript word that is not an everyday
   word in any dictation language (macOS spelling dictionaries, offline,
   `SpellCheckerLexicon`), and only for user words of 5 letters or more that
   are one or two letters away, or the same sound under a simple
   EN/FR/ES/NL phonetic key and still close. A case-only match ("kvellio")
   is fixed only when the lower case form is not a dictionary word. So the
   Spanish adjective in "¡qué genial!" is never turned into the name
   "Genial"; deciding that needs the sentence, which only cleanup reads.
   Addresses, paths and file names are left alone.
3. Cleanup (when a mode runs the model): the words go in as "Protected
   spellings" and the prompt asks the model to write a near-miss of one of
   them the user's way when the sentence uses it as that name, and to leave
   ordinary words alone. `CleanupAcceptance` excuses exactly that: a spoken
   word replaced by a protected word that sounds like it is neither "added"
   nor "dropped". Every other check is unchanged. The user's words keep the
   case they went into the model with (`GlossaryNearMiss.restoringCase`),
   and the glossary pass runs again after the rewrite.
   Measured 2026-10-18 with the pinned Qwen 2.5 1.5B on the warm server, 19
   synthetic EN/FR/ES sentences (near misses and false friends): 7 of 19 right
   before, 14 with the deterministic pass alone, 15 with the new pass, prompt
   and guard; no false friend was rewritten; median model time 126 ms before
   and 141 ms after (longer prompt), the deterministic pass about 2 to 4 ms
   per dictation (`--words-cleanup-eval`, debug builds).

Keep glossary entries specific. Do not add short common words as variants.

### Learn from my fixes

`AutoLearnWatcher` follows a paste for at most 20 s (on by default, Setup >
DICTATION > LEARN FROM MY FIXES, lockable by a profile). It starts only after
`.pasted` or `.pastedBestEffort`, not in terminals, not while secure input is
on, not in secure text fields, and only when the field's value can be read.
An Accessibility insertion gives the exact range; for a Cmd+V paste the
stretch is found right before the caret, or as its only occurrence. A light
main-thread poll (0.75 s, every Accessibility call bounded by the 0.35 s
messaging timeout) re-reads only that field and keeps the stretch between the
unchanged text before and after it. It stops when 20 s pass, focus leaves the
field or the app, the next dictation starts, secure input turns on, or the
text around the stretch changes; then `AutoLearn.proposals` diffs the pasted
text against the stretch word by word (longest common subsequence, CJK
characters as words). A substitution is learned only when all of these hold:

- one to three words on each side, and at most 3 learns per dictation; a
  dictation where more than half the words changed is a rewrite, not a fix;
- the fix is not an address, number, emoji or file name (`@`, `://`, `/`,
  `name.ext`, no letters);
- it is not only a case or punctuation change of the same words (an accent
  added to a name, or a split word joined, does count);
- it looks like a name or term: capitalized, capitals inside, or letters with
  digits (`GPT-5`);
- it is not an everyday word in the dictation languages, unless it is a
  capitalized one replacing a spelling the engine invented, away from a
  sentence start ("jenial" fixed to "Genial");
- it resembles what was heard (30 % letter similarity or the same first
  sound);
- it is not on the never-learn list.

The fix becomes a word marked `learned` in `glossary.json`, with the misheard
spelling as its "sounds like" when that spelling is safe to swap (not an
everyday word). A fix of a word already saved adds only the "sounds like".
The MIC tab says "Learned Genial." with UNDO, and a banner with Undo appears
when the controls are closed (the word shows in it only when Text in
notifications is on). WORDS marks learned words with LEARNED. UNDO, or
deleting a learned word in WORDS, writes its folded spelling to
`learn-never.json`, so it is never learned again.

## Numbers

`NumberStyle` (config key `numberStyle`, per-app override, managed key) picks
AS SPOKEN, DIGITS or WORDS. `NumberForms` is the deterministic pass, pure and
unit-tested, so it works with cleanup off. Its language is the dictation
language when it is `en`, `fr`, `es` or `nl`; on AUTO, `NLLanguageRecognizer`
detects it offline per transcript and the pass is skipped below 0.6
confidence or for any other language.

- DIGITS parses number words with `NumberLexicon` atoms: units, teens, tens,
  hundreds, thousands, millions, the joiners "and/et/y/en", French
  "quatre-vingt-dix" and "soixante et onze", Dutch compounds
  ("vijfentwintig", "negentienhonderd"), decimals ("point", "virgule",
  "coma"/"punto", "komma"/"punt") and percent. It converts numbers of 10 and
  up, decimals, years, and any number before a percent or unit word. A lone
  one-to-nine word stays a word: "one of them", "un ami", "uno de ellos",
  "een huis" cannot be told apart from a count without context. Two numbers
  side by side ("three thirty", "one two three") are left alone, except an
  English year ("nineteen eighty four").
- WORDS spells digits with Foundation's `NumberFormatter` `.spellOut` in the
  dictation locale (soft hyphens removed). It keeps years, times, versions,
  codes, list markers, phone-like runs, decimals with more than two places,
  numbers over 999,999 and digits glued to or right after an identifier
  ("GPT-5", "M5", "iOS 26").
- Both never touch URLs, emails, code-looking tokens, glossary canonicals or
  snippet phrases.

Order: the pass runs after cleanup, the glossary re-pass and spoken commands,
and before snippets and translation. Before snippets, because a snippet's
stored text must be pasted exactly as saved; the snippet phrases themselves
are protected with the same matcher `SnippetLibrary.expanding` uses
(`phraseRanges`), so a phrase saved as "twenty one pilots" still matches in
DIGITS. Before translation, so it reads the language that was spoken.

With cleanup on, the prompt gets one rule for the style (AS SPOKEN adds
nothing, so its prompt is unchanged), and `CleanupAcceptance` compares both
sides through `NumberForms.canonical` (every number as plain digits) when the
style is DIGITS or WORDS: "twenty five" written "25" is the same word, while a
changed value still counts as new and dropped words. The pass runs after
cleanup too, so the result does not depend on the model following the rule.
Measured on 24 synthetic EN/FR/ES/NL sentences with Qwen 2.5 1.5B: the pass
alone and pass plus cleanup were both 24/24 per style; the model alone
applied the rule in 5/24 DIGITS cases; no rewrite was rejected; model time
stayed within noise (reproduce with `--numbers-cleanup-eval` in a debug
build).

Snippets run after the glossary, cleanup, spoken commands and numbers: an exact spoken phrase expands to
stored text from `snippets.json`. Words and snippets can be exported and
imported from the WORDS tab. Rules and file formats: `docs/WORDS_FILES.md`.

## Data handling

- Audio files are created under the macOS temporary directory.
- Audio files are deleted after transcription completes or fails.
- Live preview audio stays in memory only. File transcription writes its converted WAV and parts to an owner-only temp folder that is deleted when the job finishes, fails, is canceled, or the app quits.
- Transcript text is not written to disk by default.
- Persistent app-created files are `config.json`, `glossary.json`,
  `snippets.json` (once you save a snippet), `learn-never.json` (once you undo
  or delete a learned word) and `stats.json` under `~/Library/Application Support/YappYapp/`.
- Learn from my fixes reads a field's text only within its 20 s window and
  only in the field YappYapp just pasted into; only the pasted stretch is
  compared. Nothing it reads is logged, kept or sent anywhere. Only a learned
  word (in `glossary.json`) and the spelling of a word you undid or deleted
  (in `learn-never.json`) are saved. The support report shows counts only.
- `stats.json` is schema-versioned and written atomically with owner-only
  permissions. The previous validated primary is retained as a backup. A bad
  primary is preserved as a numbered `.corrupt-N` quarantine file, then
  recovered from a valid backup when possible; unsupported future schemas are
  rejected explicitly instead of being silently rewritten.
- Optional settings backup archives created by `scripts/import_settings.sh` live
  under `~/Library/Application Support/YappYapp/settings-backups/`.
- Model files, the opt-in `server.log`, smoke-test markers, and backup archives are excluded
  from the settings export/import allowlist unless explicitly handled by a
  future migration.
- `server.log` is disabled by default. When a developer explicitly enables it
  with `YAPPYAPP_WHISPER_SERVER_LOG=1`, each server launch truncates the file and
  stores it with owner-only `0600` permissions.
- `scripts/reset_app_data.sh` dry-runs by default and preserves downloaded models
  plus settings backups unless the user explicitly opts into deleting them.
- The clipboard receives transcript text only after Accessibility insertion fails (Cmd+V staging, or copy-only). Writes are current-host-only and carry `org.nspasteboard` Transient/AutoGenerated markers; the previous clipboard always comes back after an inserted paste (no setting; copy-only and withheld outcomes keep the transcript), and a restore never re-posts an item marked Concealed or Transient.
- `DictationDeliveryCoordinator` owns the end of the pipeline: it routes each finished transcript (paste, queue behind an in-flight paste, or copy and notify when a newer session took over), copies only when the front app changed since recording started, and presents confirmed, unconfirmed and not-delivered outcomes as distinct phases. `deliver(text:to:)` and `lastTranscript` (memory only) are the reusable entry points.
- The control window can remain open while the app is idle; separate
  click-through HUD windows are shown during recording/transcription.
- Native fields are attempted through Accessibility value insertion first; browsers, terminals, and known Electron/WebView apps use pasteboard + Cmd-V so web/editor state receives a real paste event.

## Permissions

- Microphone: required for recording.
- Accessibility: required for automatic paste into other apps.
- Input Monitoring: not required. Chord shortcuts are Carbon hot keys. The opt-in one-key trigger (Right Option, Fn and friends) uses NSEvent global monitors, which need the Accessibility permission auto-paste already uses.

## Verification layers

- `Tests/YappYappTests` is a real Swift Testing target for focused pure-logic
  behavior.
- `YappYapp --self-test` is the bundle-integrated suite for persistence,
  concurrency state machines, accessibility behavior, and deterministic
  offscreen Brutalist UI/pixel-pet rendering.
- `scripts/e2e_test.sh` exercises synthesized audio through the local
  transcription pipeline.
- `scripts/verify_release.sh` adds source-install, managed/offline config,
  settings backup/reset, packaging, launch, policy, provenance, DMG, signature,
  and release-artifact workflows.
