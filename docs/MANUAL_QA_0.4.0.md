# Manual QA for 0.4.0

Run this with the real, packaged app before publishing 0.4.0. Automated checks
cannot see permissions, real hardware, real apps or real models. Every item
below comes from a 0.4.0 fix track and was not checked with the app running.

Setup: package with the real signing identity after running
`scripts/bootstrap_whisper_cpp.sh` and `scripts/bootstrap_llama_cpp.sh`. Use a
fresh macOS user account (or a second Mac) for section 1, and your own account
for the rest. Tick each box, and note the macOS version and Mac model at the top
of `dist/manual-qa-report.md`.

Must pass before publishing: sections 1, 2 and 3, and the first item of 11.

## 1. Fresh install and first run

Uninstall first (quit YappYapp, run `./scripts/reset_app_data.sh --apply
--include-models`, and remove YappYapp from Privacy & Security > Microphone and
Accessibility), so the walk-through starts with no models and no permissions.
Count the clicks: the expected path is CONTINUE, USE THESE, ALLOW MIC + macOS
Allow, ALLOW + the System Settings switch, ADD WORD, ADD SNIPPET, CONTINUE,
FINISH (10 clicks, plus typing the word and the snippet), plus 2 for the
test dictation and your Mac password if System Settings asks for it. The mic
and auto-paste steps move on by themselves.

- [ ] Launch: the control window opens on its own on STEP 1 OF 6, YOUR
      LANGUAGES. Pick FRANÇAIS under APP LANGUAGE: the whole screen, the menu
      bar menu and the later steps switch at once, no relaunch. Switch back.
- [ ] I SPEAK: AUTO is selected; picking a language clears AUTO, clearing the
      last language selects AUTO again. TRANSLATE TO stays OFF unless you pick
      one.
- [ ] CONTINUE: DETECT BEST MODELS shows one detected line (chip, memory,
      macOS, free space) and SPEECH, CLEANUP and TRANSLATION, each with a size
      and one reason, plus TOTAL DOWNLOAD. Nothing downloads yet (no network
      activity, no progress anywhere).
- [ ] BACK, pick 中文 or 日本語 under I SPEAK, CONTINUE: the speech pick
      changes to a model that covers it (Large v3 Turbo, Small on 8 GB,
      Parakeet Japanese for Japanese alone) and the reason says why.
- [ ] CHANGE on each row opens its choices; DONE closes it; the total follows.
- [ ] USE THESE starts the speech model first; cleanup and translation say
      AFTER THE SPEECH MODEL and start when it lands. The DOWNLOADS strip
      follows you on the next steps.
- [ ] ALLOW THE MIC: ALLOW MIC shows the macOS prompt only now. Allow moves on
      by itself. Denied: the step says the mic is blocked and OPEN SETTINGS
      opens the Microphone list; turning YappYapp on there brings the window
      back on the next step.
- [ ] ALLOW AUTO-PASTE: ALLOW opens System Settings > Accessibility. Turn
      YappYapp on and switch back: the step moves on at once, no relaunch.
      Turning it on without switching back brings the window forward by itself.
      SKIP moves on; later, MIC shows the AUTO-PASTE NOT ALLOWED YET banner.
- [ ] Dropdowns never move the card: open APP LANGUAGE and TRANSLATE TO, and
      on MODELS open CHANGE on SPEECH and its list. Each list floats under its
      field over the rows below; nothing under it shifts. Down/Up arrows move
      the yellow row, Return picks, Escape closes, a click outside closes it
      without clicking what is under it. The same on SETUP (MICROPHONE, APP
      PROFILES > ADD APP and each profile's LANGUAGE, CLEANUP, MODEL), in the
      control window and in the menu-bar popover. A list near the bottom opens
      upward. VoiceOver reads the field as expanded and the list as a group.
- [ ] WORDS AND SNIPPETS: STEP 5 OF 6 shows WORD and SNIPPET side by side,
      each with one line of what it is and a yellow example (yap yap ->
      YappYapp, my email -> an address). CONTINUE stays greyed out until both
      are added; there is no SKIP, BACK works. A word already in WORDS
      ("YappYapp"), a one-word phrase ("email") or a phrase your word rewrites
      shows the WORDS tab's own message in red. ADD WORD and ADD SNIPPET turn
      each card into a green ADDED line with what was saved. After FINISH,
      WORDS shows the word and SNIPPETS the snippet at the top, and
      glossary.json and snippets.json hold them.
- [ ] TRY IT: while the model downloads, the button is greyed out and the
      strip shows the %; SAY THIS shows a sentence with your word (yellow) and
      your snippet phrase (blue). When the model lands, press Option+Space or
      the button, say it, press again: IT WORKS. YOU SAID: shows the text with
      the word and the pasted text marked, and a check for each. Say the
      snippet phrase differently: the card turns yellow and says the snippet
      didn't fire and what to say. FINISH opens MIC, with no leftover "Setup
      saved." bar.
- [ ] Close the window mid-way (any step) and reopen from the menu bar: the
      same step shows and downloads kept going. Quit mid-way and relaunch: with
      the model already on disk, the run resumes at the first open step.
- [ ] Wi-Fi off, then USE THESE: the strip shows the plain reason (No internet
      connection) and RETRY; RETRY works once back online. TRY IT says the
      model didn't download.
- [ ] Downloads off by a profile: DETECT BEST MODELS says so, offers CONTINUE
      only, and nothing downloads.
- [ ] With no model, press Option+Space: the indicator turns yellow with "!"
      (VoiceOver reads NO MODEL) and the window shows the current setup step.
- [ ] The microphone prompt text is localized (macOS uses the system
      language).
- [ ] Wi-Fi off, start a download: the row shows FAILED with a plain reason and
      RETRY; Models shows a red message with X; RETRY works once back online.
- [ ] Revoke Accessibility after setup: only the yellow banner asks (no
      duplicate MIC row). During the wizard only the numbered step asks.
- [ ] Enable Start at Login, finish setup, log out and in: the control window
      does NOT open. Launch from Finder: it opens. It does not float above other
      apps or follow into full-screen spaces.
- [ ] On a Mac where the login item needs approval, toggle START AT LOGIN: NEEDS
      APPROVAL shows and OPEN LOGIN ITEMS opens the right System Settings pane.
- [ ] Gatekeeper: the non-notarized first-open steps in `docs/GATEKEEPER.md`
      work on macOS 14 and 15 or 26.

## 2. Delivery honesty and paste

- [ ] TextEdit: green check and PASTED; the pet celebrates.
- [ ] Browser text field: PASTED?; no celebration; with restore on, the status
      says to press COPY under HISTORY.
- [ ] Password field: yellow NOT PASTED, SECURE INPUT · TEXT KEPT, the status
      points to HISTORY and names the app that turned secure input on. With the popover closed, a "Dictation not pasted"
      notification appears; its Copy works and clipboard managers treat it as
      concealed.
- [ ] Start in app A, switch to B, then stop: the text pastes into B and B's
      app profile applies. Stop in B, switch to C while it transcribes: the
      text pastes into C. Stop with YappYapp in front: it pastes into the last
      app you used.
- [ ] Focus moves mid-dictation: click text box A, start dictating, click text
      box B (a Ghostty window running a terminal multiplexer, and a second native app), stop.
      The text lands in B, never in A, without copying it from HISTORY. Ghostty
      keeps a solid cursor the whole time (the indicator never takes focus).
      Repeat with the indicator at the BOTTOM while clicking a Ghostty prompt
      right above the bar: the click reaches Ghostty. Click the stop square on
      the bar: Ghostty stays focused and the text lands there. Help > support
      report: each delivery line shows yappyappActive=no, keyWindow=none,
      focusedApp=target and focusedElement=target (or unknown for terminals).
- [ ] Overlap: stop, start a second dictation at once on a slow model. The
      first is copied and announced; the second pastes.
- [ ] The first notification ever asks for permission at that moment, not at
      launch. With Show text in notifications on, the banner shows a preview.
- [ ] Auto-paste off: every dictation is COPIED ONLY / AUTO-PASTE OFF,
      including browsers and terminals.
- [ ] Dvorak or Colemak layout, dictate into a browser: Cmd+V pastes, no other
      shortcut fires.
- [ ] Copy in 1Password, then dictate into a browser with restore on: the
      1Password item is not put back.
- [ ] Fill the target-app paste matrix (TextEdit, Notes, Mail, Safari, Chrome,
      Slack, VS Code, Terminal, Notion) in `dist/manual-qa-report.md`.

## 3. Recording and audio

- [ ] Super Fast Mode with a Bluetooth mic: toggle it quickly and relaunch. The
      mic indicator goes off when the mode is off; no doubled or garbled text.
- [ ] Super Fast Mode on the system default: change the default input between
      dictations; the next one records from the new mic.
- [ ] Built-in speakers: the transcript never starts with the chime; check
      whether the first word right after the chime is clipped (the trim cuts
      350 ms). With headphones nothing is trimmed.
- [ ] Super Fast Mode, noisy room, double-tap the hotkey: discarded as
      accidental, nothing transcribed.
- [ ] Unplug a USB mic mid-dictation, or close the lid: the take finishes with
      the audio so far and the matching message.
- [ ] Multichannel interface with the voice on input 2: transcribed.
- [ ] Stopping a Bluetooth recording does not freeze the UI.
- [ ] `scripts/route_change_test.sh --run` on a Mac with two inputs prints
      PASSED only after a real interruption, else NOT PROVEN (exit 3).
- [ ] Esc during recording: the indicator turns ink with an x and a blue
      undo-arrow button (tooltip "Keep it"); pressing it within 5 s transcribes
      and pastes into the app in front. With the Esc setting off, Esc
      reaches the front app.
- [ ] Time limit set to 20 s: the level meter turns red for the last 10 s,
      then it stops on its own and the MIC status explains it.
- [ ] Quit mid-recording or mid-transcription: no `yappyapp-*.wav` left in
      `$TMPDIR`. A leftover older than 2 minutes is removed at the next launch.

## 4. Engines

- [ ] Whisper with Quiet Voice Boost: a 5 to 10 minute dictation completes. If
      it times out, the message mentions Retry Last Dictation and retrying
      pastes the text. The next short dictation is fast.
- [ ] With Whisper selected, `ps -axo args | grep whisper` shows a random
      `--port`, a `--request-path` and never glossary words; a cold CLI run
      shows `--prompt-file` with a path only.
- [ ] From a browser, a fetch to the whisper-server port with the secret path is
      refused (403, no CORS headers) and POST /load returns 404.
- [ ] `kill -9` whisper-server: it relaunches within about 1 s; repeated kills
      back off up to 60 s; dictation keeps working.
- [ ] Switch Parakeet to Whisper: memory drops. Relaunch with Parakeet: the
      first dictation is fast.
- [ ] Parakeet download progress moves smoothly.
- [ ] Room noise with Whisper: "No speech heard. Nothing was typed."
- [ ] Homebrew whisper-cpp or llama-cli still pass the helper policy and run.

## 5. Cleanup

- [ ] Setup > DICTATION > CLEANUP and the onboarding CLEANUP row say what
      cleanup is in one line; each mode shows its own line and a "you say, it
      writes" example in every app language (Spanish reads Latin American).

- [ ] Pick CLEAN: the model downloads with a moving percentage; CANCEL stops it;
      RETRY or DOWNLOAD resumes; CLEANUP MODEL READY only after the SHA-1 check.
- [ ] With the real Qwen 2.5 1.5B model, dictate in Clean, Email, List and Notes
      in English, French and Spanish: accepted, same language, sensible layout.
      The Email, List and Notes prompts were never run on the real model.
- [ ] "ship the beta on monday, no wait, on tuesday" and "on se voit lundi, non
      je veux dire mardi" in Clean: the correction is applied.
- [ ] While cleaning, the indicator's blue square shows a wand instead of the
      waveform; a slow or failed run is explained on the MIC tab.
- [ ] Typical dictations finish well inside the 8 to 20 s cleanup timeout,
      including the first one after launch.
- [ ] A build without the runtime and without Homebrew llama-cli shows NEEDS THE
      CLEANUP RUNTIME and downloads nothing.
- [ ] An existing user with the old model and `llmCleanup: true` sees CLEAN and,
      after one hash pass, CLEANUP MODEL READY.

## 6. Shortcuts, commands and retry

- [ ] Default: Option+Space starts and stops, Esc cancels, MIC reads PRESS TO
      TALK.
- [ ] Hold Option+Space 2 s: one start, no repeat storm. Lose the key-up by
      switching apps mid-hold: the next real press works first time.
- [ ] Hold mode relies on Carbon key-release events for Option+Space: confirm
      they arrive on this macOS.
- [ ] Record a new combo (Control+Option+D): Option+Space stops working, the new
      one works, and the recorder catches Option+Space instead of dictating.
- [ ] Recorder rejections (plain letter, Command+Space, a duplicate) and the
      Option+Space and Option+E warnings read well.
- [ ] Hold: release stops, a quick tap cancels. Hybrid: tap latches, a hold over
      300 ms stops on release.
- [ ] One-key trigger (Right Option, then Fn) with Accessibility: works from
      other apps; Right Option plus a letter still types the accent and cancels;
      check whether the Fn Globe action also fires. Before Accessibility is
      granted, the red notice shows and it starts working after granting.
- [ ] Paste Last bound and from the menu re-pastes; with nothing yet it says so.
- [ ] Say "Hello. New line. Thanks." into TextEdit, Notes, Slack and a browser:
      the line break lands with no stray space. "a new line of shoes" and "can
      you delete that" stay as spoken.
- [ ] Dictate, then dictate only "Scratch that.": exactly the previous text is
      removed.
- [ ] Undo Last after a Cmd+V paste: one Cmd+Z after the keys are released;
      after switching apps it says to switch back; after typing more it refuses.
- [ ] Retry Last after switching models re-transcribes with the new model; no
      file left in `$TMPDIR`. After a forced failure RETRY shows on HUD and MIC.
- [ ] Have another app grab Option+Space before launch: SHORTCUT UNAVAILABLE row
      and red chip; the tooltip no longer mentions Option+Space.

## 7. Words, snippets, profiles, live preview, files

- [ ] Words tab: + ADD A WORD inserts at the top with the cursor in
      WRITE IT AS. Empty spelling, duplicate, or a variant like "the" shows a
      red message and FIX MARKED WORDS.
- [ ] X on a saved word or snippet deletes it at once ("Word deleted."), with
      no SAVE needed; the WORDS and SNIPPETS counts drop with the row, and the
      next dictation no longer uses it. Edits to other rows stay unsaved.
- [ ] Snippet "my email address": inserted mid-sentence and on its own (no
      trailing period). A multi-line snippet keeps its line breaks in Mail,
      Slack and a browser.
- [ ] IMPORT and EXPORT panels open in front, also from the menu-bar popover
      (check the preview survives). Re-importing your own export says ALREADY
      HERE. A clashing snippet honors KEEP MINE and USE THEIRS. `snippets.json`
      is mode 0600.
- [ ] Per-app profile: ADD APP lists this run's apps first, never YappYapp. A
      Slack profile with FR and COPY ONLY: badge SLACK · FR · model, text
      copied. Other apps paste in the Setup language. The profile follows the
      app where the dictation ends: start in Mail, stop in Slack, and the Slack
      profile applies.
- [ ] A profile with another Whisper model while Keep Model Warm is on uses the
      CLI for that app and the warm server elsewhere. Another Parakeet variant
      is slower on first use. A profile on CLEAN without the model delivers raw
      text with the note.
- [ ] Live preview on with Parakeet: the strip appears within 1 to 2 s, updates
      once a second, disappears at stop, is never pasted; the final text is not
      slower; CPU stays reasonable; with Keep the Model Loaded off it still starts.
- [ ] The compact indicator (about 160 by 27 pt, no words in it) at BOTTOM and
      TOP and on a notched display: preview strip, bar and pet line up. LEFT and
      RIGHT: a thin vertical bar centered on that edge, meter running along it,
      no preview strip; KEEP and RETRY still click; outcomes stay
      click-through. The pet: standing on the bar at BOTTOM, hanging upside
      down under it at TOP (hearts and Zzz still upright, nothing under the
      menu bar or the notch), sitting on the bar's upper end facing the screen
      at LEFT and RIGHT. Clicks on the pet or the empty space around the bar
      reach the app underneath.
- [ ] COPY on a HISTORY row, COPY on FILES and COPY on the support report: the
      indicator shows COPIED and shrinks back to the idle pill after about
      1.5 s. COPY while dictating leaves the listening bar alone.
- [ ] Drop an m4a, an mp3 and a mov on FILES and on MIC (popover and control
      window): DROP TO TRANSCRIBE overlay, the window switches to FILES,
      progress card, result under RESULTS (COPY, SAVE to .txt), NOT in the MIC
      history, PASTE LAST or the clipboard until COPY, nothing pasted. The menu item opens the panel in front. A 30+ minute file
      on both engines, CANCEL mid-way: the `yappyapp-file-*` folder disappears.
      A dictation during a file job still pastes promptly.

### Learn from my fixes

Setup > Dictation > LEARN FROM MY FIXES on (the default). Use a word that is
not in WORDS, such as a client name YappYapp misspells.

- [ ] TextEdit: dictate a sentence with the name, retype the misspelled word
      within 20 s, click elsewhere. MIC shows "Learned <name>." with UNDO,
      WORDS shows the word with LEARNED and the misheard spelling under
      SOUNDS LIKE. The next dictation of that name comes out right.
- [ ] Notes: same check. With the controls closed a banner says YappYapp
      learned a word, with Undo; the word shows in it only when Show text in
      notifications is on. Undo from the banner removes it from WORDS.
- [ ] A browser text field (Safari or Chrome, a plain textarea such as a
      GitHub comment box): same check after the Cmd+V paste.
- [ ] A terminal (Terminal, iTerm2 or Ghostty): fix a word after a paste.
      Nothing is learned.
- [ ] Nothing is learned for: a lower case fix ("by" to "buy"), a case-only
      fix ("genial" to "Genial"), an email address or URL, a whole sentence
      rewritten, a fix made after 20 s, a fix after switching apps, a password
      field.
- [ ] UNDO on MIC, then the same fix again: nothing is learned. X on a
      LEARNED word in WORDS, then the same fix: nothing is learned.
- [ ] Switch it off: fixes are not learned. A managed `learnFromFixes` key
      shows the row LOCKED.
- [ ] The support report shows the learned and never-learn counts and the
      setting, never the words.

### Numbers

- [ ] Setup > DICTATION shows NUMBERS under CLEANUP with AS SPOKEN, DIGITS and
      WORDS, one line and a YOU SAY / IT WRITES example for the picked one, in
      all four app languages and at the LARGER text size.
- [ ] AS SPOKEN: dictate "twenty five people": the text is what the speech
      model wrote.
- [ ] DIGITS, cleanup AS SPOKEN: "we need twenty five people, one of them is
      late" pastes "25 people, one of them". "three point five percent" pastes
      "3.5%". "nineteen eighty four" pastes "1984". In French "vingt-cinq
      personnes et un ami" pastes "25 personnes et un ami"; in Spanish "en un
      momento llegan treinta y cinco" keeps "en un momento"; in Dutch
      "vijfentwintig mensen" pastes "25 mensen".
- [ ] DIGITS with cleanup CLEAN: same results, no "CLEANUP CHANGED TOO MUCH".
- [ ] WORDS: "25 people at 3:30 in 2026 with GPT-5 on iOS 26" pastes
      "twenty-five people at 3:30 in 2026 with GPT-5 on iOS 26".
- [ ] A snippet saved as "twenty one pilots" still expands in DIGITS. A word
      in WORDS with a number in it ("Area 51") is never rewritten.
- [ ] Dictation language AUTO: an English and a French dictation are each
      converted; a German dictation is left as spoken.
- [ ] App profile: give Terminal NUMBERS DIGITS. The row reads "NUMBERS
      DIGITS"; a dictation into Terminal gets digits, other apps follow Setup.
- [ ] A managed `numberStyle` key shows the row LOCKED, and a profile cannot
      override it. The support report shows "Numbers: digits".

## 8. Setup, pet and support

- [ ] Corrupt `config.json` in a throwaway account: SETTINGS FILE REPAIRED shows
      once, downloads stay off where they were off, guided setup does not
      return.
- [ ] A Setup change while an error shows: "Setup saved." flashes on the
      current tab; the MIC error stays.
- [ ] Cmd+C, V, X, A and Z work in glossary and settings fields; Cmd+Q quits,
      Cmd+W closes, Cmd+, opens SETUP.
- [ ] Parakeet selected: notes under Language, Quiet Voice Boost and Translate;
      the menu says "Language (Whisper models)".
- [ ] PET AND QUESTS off: off notice and TURN ON, no pet in popover or HUD, no
      confetti or jingles, TODAY and STREAK still count.
- [ ] With a pet visible, the last controls on Models, Words, Pet and Setup sit
      above it and clicks pass through the pet.
- [ ] Save a recap card twice: two files in `~/Pictures/YappYapp`, no Desktop
      prompt, Finder reveals the new one.
- [ ] Locked pet rows show the new copy and progress without clipping at default
      and LARGER text. Check the "SAVED BY A NEWER YAPPYAPP" banner tone.
- [ ] COPY REPORT: no user name, device name, glossary or prompt text;
      version and build right. SAVE AS FILE works. A real `.ips` appears under
      RECENT CRASHES and REVEAL selects it.

## 9. Accessibility and text size

- [ ] Full Keyboard Access: every button, chip, toggle, field and the auto-stop
      slider shows the blue ring; mouse clicks show none.
- [ ] VoiceOver: "Listening.", "Transcribing." and the paste outcome once each;
      an error speaks "Needs attention." with the detail.
- [ ] TEXT SIZE SMALL to LARGER resizes the whole popover at once, survives a
      relaunch, and every tab scrolls to its last control at LARGER.
- [ ] Section headers (including DICTATION) show a solid ink bar, no paper line.
- [ ] Hidden scroll indicators are still acceptable now that LARGER scrolls
      every tab.

## 10. Languages

- [ ] APP LANGUAGE through every option: tab, header and tab bar switch at once;
      after autosave the main menu and right-click menu follow.
- [ ] On System, set macOS to French, Spanish, Dutch and an unsupported language
      in turn: the app follows, or falls back to English.
- [ ] Notifications (copied only, failed, secure input) in fr, es and nl,
      including the Copy button.
- [ ] Truncation in each language in the first-run wizard, profile chips,
      shortcut rows, cleanup status line and the INDICATOR POSITION chips.
- [ ] A native speaker reviews French (vous), Latin American Spanish (tú) and
      Dutch.

## 11. Managed Macs and the release build

- [ ] Packaged app: `--l10n-status` lists 985 strings per language; `otool -l`
      on the app and `Resources/bin/*` shows no `/Library/Developer` or `.build`
      rpaths; the app and Sparkle launch.
- [ ] Install a configuration profile (sample in `docs/MANAGED_INSTALLS.md`):
      LOCKED tags, disabled controls, the locked Models row and the locked Pet
      view look right; values from both the custom-settings and the legacy
      ManagedClient payloads are read; removing the profile restores the user's
      own values. Forced language or autoPaste shows LOCKED in each app profile.
- [ ] A 0.3.1 install offers 0.4.0 through the matd97 feed after publishing.
- [ ] `brew install --cask migueltorrezd/tap/yappyapp`, then
      `brew uninstall --zap --cask yappyapp` on a spare account.
- [ ] After a Developer ID build: drop disable-library-validation, then confirm
      launch and a Sparkle update check; notarization accepts the nested
      `YappYapp_YappYapp.bundle`.

## 12. Interface copy (writing pass, 2026-10-16)

- [ ] MIC headline follows the phase in the real app: NOT READY YET on a fresh
      account, then the mode wording when ready, LISTENING, TRANSCRIBING,
      CLEANING UP with a cleanup mode, PASTED, and NOT PASTED or COPIED with the
      reason. The green READY banner only shows when idle with nothing to fix.
- [ ] First run names each step (YOUR LANGUAGES, DETECT BEST MODELS, ALLOW
      THE MIC, ALLOW AUTO-PASTE, WORDS AND SNIPPETS, TRY IT) with STEP N OF 6
      and one sentence
      each. After FINISH, anything left open shows on MIC as a plain list. Tips
      stay hidden until setup is done.
- [ ] Every not-pasted case (password field, no text field, auto-paste off)
      points to HISTORY or ⌘V and never says to dictate again;
      the text really is in HISTORY.
- [ ] A successful paste turns the indicator green with a check, and MIC says
      "Done in".
- [ ] SETUP shows the eight sections in order (DICTATION, MICROPHONE, PASTING,
      APP PROFILES, INDICATOR AND SOUND, SPEED, APP, HELP) with QUIT YAPPYAPP
      and "Quitting clears history." at the bottom. Every pick-one row is one
      even segmented row or a dropdown, nothing wraps, and every row uses the
      same type. MORE SHORTCUTS opens; DICTATE and CANCEL are one field each
      (click, press keys); clearing CANCEL with its x lets Esc reach the front
      app.
- [ ] There is no clipboard switch. Copy something, dictate into a text field:
      after the paste, your copied item is back on the clipboard.
- [ ] INDICATOR POSITION offers BOTTOM, TOP, LEFT, RIGHT and OFF on one line.
- [ ] MODELS marks Parakeet TDT v3 as RECOMMENDED, shows a size on every row
      and keeps Whisper folded unless a Whisper model is in use.
- [ ] Read the MIC, SETUP and MODELS tabs once in French, Spanish and Dutch:
      nothing is cut off and the wording sounds natural to a native speaker.

