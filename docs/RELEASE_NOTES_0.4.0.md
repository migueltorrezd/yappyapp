# YappYapp 0.4.0

Version 0.4.0 (build 6). Apple Silicon, macOS 14 or newer.

This release makes YappYapp tell the truth about every dictation, fixes the
first run, and adds the features people asked for most. Your voice still never
leaves your Mac.

- **Signed and notarized.** YappYapp is now signed with an Apple Developer ID
  and notarized by Apple, so it opens with a normal double-click. No more
  Open Anyway.
- **Open source.** The source code is public under the MIT License at
  <https://github.com/migueltorrezd/yappyapp>.

## What's new

- **Clearer words everywhere.** Every screen now uses one name per idea
  (Setup, words, cleanup, paste, history, shortcut). The MIC tab headline
  always says what is happening, a failed paste says where your text is
  instead of asking you to dictate again, and a successful paste shows how long
  it took. Setup is reordered by what you change most: Dictation, Microphone,
  Pasting, App profiles, Indicator and sound, Speed, App, and Help. Every choice
  uses the same controls and one type scale, and help lines read as sentences.
  The clipboard you had always comes back after a paste, so that switch is gone.
  A canceled dictation now comes back with KEEP, so UNDO only ever means
  taking pasted text back out.
- **Shortcuts your way.** Change the dictation shortcut in Setup > Dictation.
  Pick Press, Hold (push to talk) or Both, or use one key on its own (Right
  Option, Right Command, Right Control or Fn).
- **Paste Last, Retry Last, Undo Last.** Paste your last dictation again, run
  the last recording through the model again, or take the last dictation back
  out. All of it stays in memory and is gone when you quit.
- **Cleanup modes.** Verbatim, Clean, Email, List and Notes, run by a small
  local model (about 1.1 GB, downloaded only when you pick a mode). "Monday, no
  wait, Tuesday" comes out as Tuesday. If a rewrite looks wrong, you get your raw
  words instead, and the app says why.
- **Translation.** Pick a language under TRANSLATE TO (English, French,
  Spanish, Dutch, German, Portuguese, Italian, Japanese, Chinese, Korean) and
  your dictation goes out translated, on this Mac. Hy-MT2 1.8B (about 1.1 GB)
  is quick everywhere; Hy-MT2 7B (about 4.6 GB) is best on Macs with 24 GB or
  more. Whisper's built-in English translate still works with a Whisper model.
  The old TRANSLATE TO ENGLISH switch carries over. If the model is missing or
  fails, your words go out untranslated and the app says so.
  With Keep the model loaded on, the translation model stays warm like the
  cleanup model: about 0.3 s per dictation with 1.8B, under 1 s with 7B.
- **Parakeet Ultra is the new default.** Same 25 languages and speed as
  Parakeet TDT v3, with fewer mistakes (about 630 MB, one time). New installs
  start on it and SCAN MY MAC suggests it. If you already use v3, nothing
  changes until you pick Ultra in MODELS; v3 stays in the list.
- **Qwen3-ASR.** A third speech engine for the languages Parakeet does not
  cover: Chinese, Japanese, Korean, Arabic, Hindi and more, 52 languages and
  dialects in all. Pick Qwen3-ASR 0.6B (about 1 GB, quick) or 1.7B (about
  2.5 GB, most accurate) in the new QWEN3-ASR group on MODELS. On AUTO it
  detects the language itself; a picked language steers it. It runs on this
  Mac through the bundled llama.cpp runtime, warm with Keep the model loaded
  on (about 0.15 s to 0.3 s for a short dictation on an M5 Pro). FILES works
  with it too, and DELETE on its row frees the space when you stop using it.
- **SCAN MY MAC.** On MODELS, one click reads your chip, memory and free space
  and suggests a speech, cleanup and translation model, with USE THIS on each.
  The speech line also names the Qwen3-ASR size that suits your Mac for
  other languages.
- **Spoken commands.** Say "new line", "new paragraph" or "scratch that" as its
  own phrase. Works in English, French, Spanish and Dutch.
- **Numbers.** Setup > DICTATION > NUMBERS: AS SPOKEN (as before), DIGITS
  ("twenty five people" becomes "25 people", "three point five percent"
  becomes "3.5%") or WORDS ("25 people" becomes "twenty-five people"). Works
  with cleanup off, in English, French, Spanish and Dutch. A lone small number
  like "one" or "un" stays a word, and years, times, versions and names like
  "GPT-5" keep their digits. App profiles can set it per app, for example
  DIGITS in a terminal.
- **Snippets.** Say "my email address", get your address. Import and export
  your words and snippets as JSON or CSV.
- **Per-app profiles.** Give Slack French and copy-only, give Mail the Email
  mode. A profile applies to the app where the dictation ends. VoiceOver reads
  which profile, language and model are active.
- **Live preview** (optional, Parakeet): see your last words above the HUD while
  you talk. Never pasted, never saved.
- **Transcribe a file.** The FILES tab takes a dropped or chosen audio or
  video file, shows its progress, and keeps the results to copy or save as
  text. FILES is separate from MIC: a file transcript stays in FILES, never
  lands in the dictation history or on the clipboard by itself, and is never
  pasted.
- **Guided first run.** Six short steps in the window: pick the app language
  (it switches at once) and the languages you speak, DETECT BEST MODELS reads
  your Mac and proposes a speech, cleanup and translation model with sizes and
  reasons, then the mic and auto-paste. WORDS AND SNIPPETS shows the
  difference side by side (a word is spelled your way: say "yap yap", get
  YappYapp; a snippet pastes a longer text: say "my email", get the address)
  and asks you to add one of each, saved to WORDS like any other. The first
  test dictation suggests a sentence with both and then shows where your word
  was spelled and your snippet expanded, or what to try if one didn't. Nothing
  downloads until you click USE THESE, the speech model downloads first, and
  permissions granted in System Settings are picked up without a relaunch.
- **Dropdowns stay put.** Every dropdown (app language, TRANSLATE TO, models,
  microphone, app profiles) now opens as a floating list under its field
  instead of pushing the screen down. Arrow keys and Return pick, Escape or a
  click outside closes it, and VoiceOver reads it as one list.
- **Languages steer the model.** Speak Japanese, Chinese, Korean, Arabic, Hindi
  or another language Parakeet doesn't cover, and the advice (in setup and
  SCAN MY MAC) moves to a model that does.
- **Your language.** The app now speaks English, French, Spanish and Dutch, and
  follows your Mac unless you pick one.
- **Easier to read.** Text size in Setup, a visible keyboard focus ring, and
  VoiceOver announces each step.
- **Support report.** Copy or save a report with versions and settings only, and
  see recent crash reports, from Setup > Help. Help also has YOUTUBE and
  LINKEDIN buttons to reach the developer; they open in your browser only when
  you click them.
- **Managed Macs.** IT can lock settings with a configuration profile. See
  `docs/MANAGED_INSTALLS.md`.
- **YappYapp learns from your fixes.** Retype a name it got wrong right after
  it pasted ("jenial" to "Genial") and it learns your spelling, says
  "Learned Genial." with UNDO, and marks the word LEARNED in WORDS. It reads
  only the text it just pasted, for a few seconds, on this Mac, and skips
  terminals and password fields. Words you undo or delete are never learned
  again. Turn it off in Setup > Dictation > Learn from my fixes.
- **Your words win more often.** A close miss of one of your words is written
  your way even with cleanup off, while everyday words stay as said
  ("¡qué genial!" keeps its adjective). With a cleanup mode on, the model also
  fixes near misses when the sentence uses them as names. Qwen3-ASR now gets
  your words as context in every run, which took it from 3 to 10 of 12 unusual
  names in our test clips.

## Fixed

- The first run no longer says READY with no voice model, no longer waits for
  the download before asking for the mic, and no longer starts anything before
  you agree. Failed downloads say why in plain words and offer RETRY.
- The indicator only turns green when the text landed. Otherwise MIC says
  PASTED?, COPIED or NOT PASTED with the reason, says your text is safe in
  HISTORY, and a notification with Copy shows up if the window is closed.
- A smaller indicator with no words in it: a tiny pill when idle, a compact bar
  while you talk that shows its state with color, a glyph and the live level
  meter. VoiceOver still reads every state. New LEFT and RIGHT positions put a
  thin vertical bar in the middle of that screen edge.
- Text lands where your cursor is when it is pasted, even if you clicked into
  another field (or a Ghostty terminal running a terminal multiplexer) while you were talking.
  The indicator no longer takes focus: clicks around it reach the app under
  it, and the stop square, KEEP and RETRY work without pulling the keyboard
  away. The support report now says who held the keyboard at each paste.
- COPY in HISTORY, FILES or the support report no longer leaves the indicator
  stuck open; it shows COPIED and shrinks back.
- The pet now lives on the indicator in every position: hanging under the bar
  at the top and sitting on its upper end on the left and right.
- Setup and onboarding explain cleanup in plain words, with a short example
  for each mode.
- A dictation that finishes while you started another one is copied, not lost.
  Switch apps mid-dictation and the text goes to the app you are in when you
  stop (or switch to while it transcribes), not the one you started in.
- Long Whisper dictations no longer time out and lose the audio. Failed
  recordings are kept for Retry.
- Super Fast Mode keeps one mic session, follows a new default mic, and stops
  ambient noise from being transcribed. The start chime no longer ends up in the
  transcript.
- Sleep, unplugged mics and stalled Bluetooth recordings finish with what was
  said.
- Esc cancel is optional and has UNDO for 5 seconds. A countdown warns before the
  time limit.
- Cmd+C, Cmd+V, Cmd+Q and the rest now work in text fields.
- The control window no longer opens at every login.
- A damaged settings file is repaired instead of reset.
- Transcripts on the clipboard stay on this Mac and are marked transient, so
  clipboard managers skip them. Password-manager items are never put back.
- Pet: travelling west no longer breaks your streak, egg level-ups are gone, and
  Pet and quests can be turned off entirely. Recap cards go to
  `~/Pictures/YappYapp` and never overwrite.

## Install

Download `YappYapp-0.4.0.dmg`, check its SHA-256 against the value on the release
page, and drag YappYapp to Applications. Double-click it and click Open when
macOS asks about an app downloaded from the internet. Homebrew:
`brew install --cask migueltorrezd/tap/yappyapp`.

**Updating from 0.3.x:** the built-in updater offers 0.4.0 as before. Because
the app is now signed with a Developer ID instead of the old self-signed
certificate, macOS asks for Accessibility and Microphone access once more.
Turn YappYapp back on in System Settings > Privacy & Security > Accessibility
and > Microphone. If an old YappYapp entry is still listed there, remove it
with the minus button first.

## Known limits

- The cleanup modes were tuned on the Clean mode; Email, List and Notes are new
  and may need prompt work after real-world use.
- The French, Spanish and Dutch translations have not had a native-speaker review
  yet.
- Translation runs on dictations, not yet on FILES transcripts. Snippet text is
  translated along with the rest of the dictation.
- NUMBERS covers English, French, Spanish and Dutch only, and dictations, not
  FILES transcripts. DIGITS leaves a lone one-to-nine word as a word unless a
  unit or percent follows, and leaves two numbers side by side ("three
  thirty") as spoken. The cleanup model rarely applies the number rule on its
  own; the deterministic pass does the work either way.
- Spoken punctuation ("period", "comma") is not supported on purpose: those words
  are too common to rewrite safely.
- Qwen3-ASR has no live preview (Parakeet only) and no Quiet Voice Boost
  decoding; with Keep the model loaded off, the one-shot run cannot take the
  language hint and always detects the language.
- Apple Silicon only.

Uninstall: `brew uninstall --zap --cask yappyapp`, or the manual steps in
`docs/INSTALL.md`.
