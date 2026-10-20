#if DEBUG
import AppKit
import SwiftUI

/// Debug-only visual audit: `--render-gallery <dir>` renders every tab and the
/// important states offscreen to PNGs, one at a time. It never launches the
/// app, opens a window, touches the pasteboard, hotkeys, microphone or
/// notifications, and refuses to run without a temporary App Support base.
enum RenderGallery {
    private static let slackID = "com.tinyspeck.slackmacgap"

    @MainActor
    static func run(outputDirectory: URL) -> Int32 {
        guard let base = ProcessInfo.processInfo.environment[AppPaths.applicationSupportBaseEnvironmentKey],
              !base.isEmpty else {
            FileHandle.standardError.write(Data("render-gallery: set \(AppPaths.applicationSupportBaseEnvironmentKey) to a scratch folder first\n".utf8))
            return 2
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("render-gallery: cannot create \(outputDirectory.path): \(error)\n".utf8))
            return 1
        }

        let previousLanguage = L10n.language
        defer { L10n.apply(previousLanguage) }
        var gallery = Gallery(directory: outputDirectory)

        L10n.apply("en")
        renderEnglish(into: &gallery)
        for language in ["fr", "es", "nl"] {
            L10n.apply(language)
            renderLocalized(language, into: &gallery)
        }

        print("render-gallery: wrote \(gallery.written) PNGs to \(outputDirectory.path)")
        for failure in gallery.failures {
            FileHandle.standardError.write(Data("render-gallery: failed \(failure)\n".utf8))
        }
        return gallery.failures.isEmpty ? 0 : 1
    }

    // MARK: - English

    @MainActor
    private static func renderEnglish(into gallery: inout Gallery) {
        // Tabs in the ready state, as the popover shows them and in full.
        let ready = readyState()
        for tab in BrutalTab.allCases {
            let name = tab.rawValue.lowercased()
            gallery.popover("en-tab-\(name)", popover(ready, tab: tab))
            gallery.body("en-tab-\(name)-full", body(of: popover(ready, tab: tab), tab: tab))
        }

        // First run.
        let fresh = freshState()
        gallery.popover("en-01-fresh-install", popover(fresh))
        gallery.body("en-01-fresh-install-full", popover(fresh).homeTab)
        gallery.popover("en-01-fresh-install-setup", popover(fresh, tab: .settings))
        // DROPDOWN-FLOAT: the Setup mic list floats over the rows below it.
        gallery.body("en-01-fresh-install-setup-mic-open-full", popover(fresh, tab: .settings).settingsTab, dropdownOpen: L10n.tr("Microphone"))

        let micAllowed = freshState()
        micAllowed.isMicrophoneAuthorized = true
        MicCheckController.shared.armGuidedStep(isFirstRun: true)
        gallery.body("en-02-fresh-install-mic-check", popover(micAllowed).homeTab)
        MicCheckController.shared.armGuidedStep(isFirstRun: false)

        let downloading = freshState()
        downloading.modelDownloads[downloading.selectedModelID] = 0.42
        gallery.popover("en-03-model-downloading", popover(downloading))
        gallery.popover("en-03-model-downloading-models", popover(downloading, tab: .models))

        let failed = freshState()
        // Parakeet Japanese: a model this Mac is unlikely to have, so its row
        // shows FAILED instead of the READY a cached model would show.
        failed.modelDownloadErrors["parakeet-ja"] = DownloadErrorCopy.offline
        // No tab banner: AppDelegate leaves the failure to the row.
        gallery.popover("en-04-download-failed-models", popover(failed, tab: .models))
        let noModel = freshState()
        noModel.phase = .error(MissingModelNotice(
            modelID: "parakeet-ultra", modelName: "Parakeet Ultra",
            downloadsAllowed: true, downloadProgress: nil
        ).message)
        gallery.popover("en-04-no-model-hotkey-pressed", popover(noModel))
        gallery.hud("en-04-no-model-hud", noModel)

        gallery.popover("en-05-ready", popover(ready))

        // ONBOARDING: every step and its states, in order.
        renderOnboarding("en", into: &gallery, full: true)

        // Dictation lifecycle.
        let recording = readyState(phase: .recording)
        recording.recordingSeconds = Int(recording.config.maxRecordingSeconds) - 7
        recording.livePreviewText = "so the plan for monday is to ship the beta and"
        gallery.hud("en-06-recording-countdown-live-preview", recording)
        gallery.popover("en-06-recording", popover(recording))

        let transcribing = readyState(phase: .transcribing)
        gallery.hud("en-07-transcribing", transcribing)
        let cleaning = readyState(phase: .transcribing)
        cleaning.hudNote = L10n.tr("CLEANING UP")
        gallery.hud("en-07-cleaning", cleaning)
        gallery.popover("en-07-transcribing", popover(transcribing))

        let pasted = readyState(phase: .pasted)
        pasted.statusText = PasteOutcomePresenter.status(for: .pasted, elapsedLabel: "0.8s").statusText
        pasted.pastedElapsedLabel = "0.8s"
        gallery.hud("en-08-pasted", pasted)
        gallery.popover("en-08-pasted", popover(pasted))

        let unconfirmed = readyState(phase: .sentUnconfirmed)
        gallery.hud("en-09-sent-unconfirmed", unconfirmed)

        let secure = PasteOutcomePresenter.status(for: .withheld(.secureInputActive))
        let notPasted = readyState(phase: secure.phase)
        notPasted.statusText = secure.statusText + PasteOutcomePresenter.secureInputHolderSuffix("1Password")
        gallery.hud("en-09-not-pasted", notPasted)
        gallery.popover("en-09-not-pasted", popover(notPasted))
        let copiedOnly = readyState(phase: PasteOutcomePresenter.status(for: .copiedOnly(.focusUnclear)).phase)
        gallery.hud("en-09-copied-only", copiedOnly)

        let canceled = readyState(phase: .canceled)
        gallery.hud("en-10-canceled-undo", canceled)

        let failedMessage = DictationFailurePresenter.message(for: WhisperError.timedOut, audioKept: true)
        let failedDictation = readyState(phase: .error(failedMessage))
        failedDictation.statusText = failedMessage
        failedDictation.retryAvailable = true
        gallery.hud("en-11-error-retry", failedDictation)
        gallery.popover("en-11-error-retry", popover(failedDictation))

        // The compact indicator in every orientation and state.
        renderIndicatorStates(into: &gallery)

        // Per-app profile badge and its settings section.
        let profiled = readyState(phase: .recording)
        profiled.config.appProfiles = [
            AppProfile(bundleID: slackID, appName: "Slack", language: "fr", cleanupMode: "clean", pasteBehavior: .copyOnly)
        ]
        profiled.dictationBadge = AppProfileResolver.resolve(
            base: profiled.config, bundleID: slackID, lockedKeys: [], isModelInstalled: { _ in true }
        ).badge
        gallery.hud("en-12-profile-badge", profiled)
        gallery.body("en-12-profiles-settings-full", popover(profiled, tab: .settings).settingsTab)
        // NUMBERS: a terminal that always gets digits, its editor open.
        let terminal = AppProfile(bundleID: "com.apple.Terminal", appName: "Terminal", numberStyle: NumberStyle.digits.rawValue)
        gallery.body("en-12-profile-numbers", AppProfilesSettingsSection(
            profiles: .constant(profiled.config.appProfiles + [terminal]),
            lockedKeys: [],
            modelChoices: [],
            cleanupModelInstalled: true,
            candidateProvider: { [] },
            initiallyExpanded: terminal.id
        ))

        // Shortcuts live in SETUP; this render shows a custom combo and the
        // one-key trigger so the whole section is exercised.
        let shortcuts = readyState()
        shortcuts.config.shortcuts.mode = .hybrid
        shortcuts.config.shortcuts.modifierHold = .rightOption
        // A bound paste last opens MORE SHORTCUTS.
        shortcuts.config.shortcuts.setChord(KeyChord(keyCode: 9, modifiers: 0x0100 | 0x0200), for: .pasteLast)
        gallery.body("en-13-shortcuts-settings-full", popover(shortcuts, tab: .settings).settingsTab)

        // Snippets.
        let snippets = readyState()
        snippets.snippets = [
            Snippet(trigger: "my email address", expansion: "miguel@example.com"),
            Snippet(trigger: "sign off", expansion: "Best,\nMiguel")
        ]
        gallery.popover("en-14-snippets", popover(snippets, tab: .words, wordsMode: .snippets))

        // Managed install.
        let managed = readyState()
        managed.managedConfigKeys = Set(ManagedConfigKey.allCases)
        managed.config.allowModelDownloads = false
        // ConfigStore applies a forced petEnabled=false to the config too.
        managed.config.petEnabled = false
        gallery.body("en-15-managed-lock-settings-full", popover(managed, tab: .settings).settingsTab)
        gallery.popover("en-15-managed-lock-models", popover(managed, tab: .models))
        gallery.popover("en-15-managed-lock-pet", popover(managed, tab: .pet))

        // Text size Larger.
        let larger = readyState()
        larger.config.textSize = BrutalTextSize.larger.rawValue
        gallery.popover("en-16-text-larger-mic", popover(larger))
        gallery.popover("en-16-text-larger-setup", popover(larger, tab: .settings))
        gallery.body("en-16-text-larger-setup-full", popover(larger, tab: .settings).settingsTab, textSize: larger.config.textSize)
        let largerRecording = readyState(phase: .recording)
        largerRecording.config.textSize = BrutalTextSize.larger.rawValue
        largerRecording.dictationBadge = profiled.dictationBadge
        gallery.hud("en-16-text-larger-hud", largerRecording)

        // Odds and ends that share the MIC tab.
        let extras = readyState()
        extras.hotkeyUnavailable = true
        extras.petEventNote = L10n.tr("%@ reached level %@.", "Cat", "3")
        extras.tabFeedback[.home] = .success(L10n.tr("Setup saved."), topic: "save")
        gallery.popover("en-17-mic-extras", popover(extras))
        gallery.body("en-17-mic-extras-full", popover(extras).homeTab)

        // WORDS after deleting rows: one saved word left plus a new blank
        // row. The counts follow the rows on screen (WORDS 1, SNIPPETS 0).
        let afterDelete = readyState()
        afterDelete.glossaryEntries = [GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)]
        afterDelete.snippets = []
        var afterDeleteDrafts = afterDelete.glossaryEntries.map(GlossaryEntryDraft.init)
        afterDeleteDrafts.insert(GlossaryEntryDraft(canonical: "", variantsText: "", notes: ""), at: 0)
        gallery.popover("en-20-words-after-delete", popover(afterDelete, tab: .words, glossaryDrafts: afterDeleteDrafts))

        // FILES: running job, then finished with results.
        let filesRunning = readyState()
        filesRunning.fileTranscription = .running(fileName: "interview.m4a", stage: .transcribing(done: 1, total: 3))
        gallery.popover("en-19-files-running", popover(filesRunning, tab: .files))
        let filesDone = readyState()
        filesDone.fileTranscription = .finished(fileName: "client-call.mov", words: 1_204)
        filesDone.recordFileResult(fileName: "standup-monday.m4a", text: "Quick sync on the launch. Design is done, copy needs one more pass, and the beta goes out Thursday if QA signs off.")
        filesDone.recordFileResult(fileName: "client-call.mov", text: "Thanks for joining. Today we want to walk through the onboarding flow, the pricing page, and what the first month looks like for your team.")
        gallery.popover("en-19-files-done", popover(filesDone, tab: .files))
        gallery.body("en-19-files-done-full", popover(filesDone, tab: .files).filesTab)

        let petOff = readyState()
        petOff.config.petEnabled = false
        gallery.popover("en-18-pet-off", popover(petOff, tab: .pet))

        // MODELS (round 2): before a scan, then SCAN MY MAC on the owner's
        // M5 Pro with the TRANSLATION family open.
        gallery.body("en-21-models-before-scan-full", popover(readyState(), tab: .models).modelsTab)
        let scanned = modelsRound2State()
        gallery.popover("en-21-models-scan", popover(scanned, tab: .models))
        gallery.body("en-21-models-scan-full", popover(scanned, tab: .models).modelsTab)
        let scannedLarger = modelsRound2State()
        scannedLarger.config.textSize = BrutalTextSize.larger.rawValue
        gallery.body("en-21-models-scan-larger-full", popover(scannedLarger, tab: .models).modelsTab.environment(\.brutalTextSize, .larger))
        gallery.popover("en-21-models-scan-larger", popover(scannedLarger, tab: .models))
        gallery.popover("en-22-setup-translate-larger", popover(scannedLarger, tab: .settings))

        // SETUP > DICTATION: TRANSLATE TO with a model still to download,
        // Whisper standing in, and ready.
        let translateMissing = readyState()
        translateMissing.config.translation = .fr
        gallery.body("en-22-setup-translate-missing-full", popover(translateMissing, tab: .settings).settingsTab)
        let translateDownloading = modelsRound2State()
        translateDownloading.config.translationModelID = .hyMT2Best
        gallery.body("en-22-setup-translate-downloading-full", popover(translateDownloading, tab: .settings).settingsTab)
        let translateSubstituted = modelsRound2State()
        translateSubstituted.config.translationModelID = .whisperBuiltIn
        gallery.body("en-22-setup-translate-whisper-swap-full", popover(translateSubstituted, tab: .settings).settingsTab)
        let translateLarger = modelsRound2State()
        translateLarger.config.textSize = BrutalTextSize.larger.rawValue
        gallery.body("en-22-setup-translate-ready-larger-full", popover(translateLarger, tab: .settings).settingsTab.environment(\.brutalTextSize, .larger))

        // QWEN3-ASR: the family open with 1.7B in use and 0.6B downloading,
        // then SETUP's captions with Qwen3-ASR as the speech engine.
        let qwen = qwen3ASRState()
        gallery.popover("en-23-models-qwen3asr", popover(qwen, tab: .models))
        gallery.body("en-23-models-qwen3asr-full", popover(qwen, tab: .models).modelsTab)
        let qwenLarger = qwen3ASRState()
        qwenLarger.config.textSize = BrutalTextSize.larger.rawValue
        gallery.body("en-23-models-qwen3asr-larger-full", popover(qwenLarger, tab: .models).modelsTab.environment(\.brutalTextSize, .larger))
        gallery.body("en-23-setup-qwen3asr-full", popover(qwen, tab: .settings).settingsTab)

        // LEARN-FROM-FIXES: a learned word in WORDS, "Learned Genial." with
        // UNDO on MIC, and the LEARN FROM MY FIXES switch in SETUP.
        renderLearnFromFixes("en", into: &gallery)
    }

    @MainActor
    private static func learnedState(_ language: String) -> YappYappState {
        let state = readyState()
        state.config.appLanguage = language
        state.glossaryEntries = [GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil, learned: true)]
            + Glossary.defaultEntries
        state.learnedWordNotice = LearnedWordNotice(proposal: AutoLearn.Proposal(
            heard: "jenial", fixed: "Genial", change: .addWord(canonical: "Genial", variant: "jenial")
        ))
        return state
    }

    @MainActor
    private static func renderLearnFromFixes(_ language: String, into gallery: inout Gallery) {
        let learned = learnedState(language)
        gallery.popover("\(language)-24-words-learned", popover(learned, tab: .words))
        gallery.popover("\(language)-24-mic-learned", popover(learned))
        gallery.body("\(language)-24-mic-learned-full", popover(learned).homeTab)
        gallery.body("\(language)-24-setup-learn-from-fixes-full", popover(learned, tab: .settings).settingsTab)
    }

    /// Qwen3-ASR 1.7B selected, 0.6B downloading, after a scan.
    @MainActor
    private static func qwen3ASRState() -> YappYappState {
        let state = modelsRound2State()
        state.config.modelPath = Qwen3ASRVariant.large.modelPath
        state.selectedModelID = "qwen3asr-1.7b"
        state.selectedModelName = "Qwen3-ASR 1.7B"
        state.modelDownloads = ["qwen3asr-0.6b": 0.42]
        return state
    }

    /// Translation on (French, 1.8B ready, 7B downloading) and a scan of
    /// the owner's Mac.
    @MainActor
    private static func modelsRound2State() -> YappYappState {
        let state = readyState()
        state.config.translation = .fr
        state.config.translationModelID = .hyMT2Fast
        state.translationModels = TranslationModelsSnapshot(
            verified: [.hyMT2Fast],
            installed: [.hyMT2Fast],
            phases: [.hyMT2Best: .downloading(fraction: 0.37)]
        )
        let profile = HardwareProfile(
            chipName: "Apple M5 Pro", modelIdentifier: "Mac17,7", memoryBytes: 48 << 30,
            macOSVersion: "26.1", freeDiskBytes: 210_000_000_000, onBattery: false
        )
        state.hardwareScan = HardwareScan(
            profile: profile,
            recommendations: ModelAdvisor.recommend(
                for: profile,
                installed: InstalledModels(speechIDs: ["parakeet-v3"], cleanupModel: false, translation: [.hyMT2Fast])
            )
        )
        return state
    }

    // MARK: - Onboarding

    /// The owner's Mac and a base 8 GB one, for the DETECT BEST MODELS step.
    private static let m5Pro = HardwareProfile(
        chipName: "Apple M5 Pro", modelIdentifier: "Mac17,7", memoryBytes: 48 << 30,
        macOSVersion: "26.1", freeDiskBytes: 210_000_000_000, onBattery: false
    )
    private static let m1Base = HardwareProfile(
        chipName: "Apple M1", modelIdentifier: "MacBookAir10,1", memoryBytes: 8 << 30,
        macOSVersion: "26.1", freeDiskBytes: 60_000_000_000, onBattery: true
    )

    /// A fresh install at `step`, scanned on `profile`, as the coordinator
    /// would have left it.
    @MainActor
    private static func onboardingState(
        _ step: OnboardingStep,
        spoken: Set<String> = [],
        translateTarget: TranslationTarget = .off,
        profile: HardwareProfile? = m5Pro,
        accepted: Bool = false
    ) -> YappYappState {
        let state = freshState()
        state.translationModels.runtimeAvailable = true
        var session = OnboardingFlow.start(
            facts: OnboardingFacts(microphoneAuthorized: false, accessibilityTrusted: false, autoPasteWanted: true, speechModelReady: false),
            configLanguage: "auto",
            translateTarget: translateTarget
        )
        session.current = step
        session.spoken = spoken
        if let profile {
            session.profile = profile
            session.recommendations = ModelAdvisor.recommend(for: profile, languages: spoken)
            session.picks = OnboardingPlan.picks(from: session.recommendations, translateTarget: translateTarget, llamaRuntimeAvailable: true)
        }
        session.accepted = accepted
        state.onboarding = session
        return state
    }

    @MainActor
    private static func renderOnboarding(_ language: String, into gallery: inout Gallery, full: Bool) {
        func shot(
            _ name: String, _ state: YappYappState, editing: RecommendationKind? = nil,
            dropdownOpen: String? = nil, words: OnboardingWordsPreview? = nil
        ) {
            state.config.appLanguage = language
            gallery.popover("\(language)-ob-\(name)", popover(state), onboardingEditing: editing, dropdownOpen: dropdownOpen, wordsPreview: words)
        }

        // WORDS AND SNIPPETS: the word and snippet a user would add.
        let word = GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)
        let snippet = Snippet(trigger: L10n.tr("my email"), expansion: L10n.tr("jane@company.com"))
        func withWords(_ state: YappYappState) -> YappYappState {
            state.glossaryEntries = [word] + state.glossaryEntries
            state.snippets = [snippet]
            state.onboarding?.addedWord = word
            state.onboarding?.addedSnippet = snippet
            return state
        }

        shot("01-languages", onboardingState(.languages, profile: nil))
        // DROPDOWN-FLOAT: APP LANGUAGE open floats over I SPEAK; the card
        // below does not move.
        shot("01-languages-dropdown-open", onboardingState(.languages, profile: nil), dropdownOpen: L10n.tr("App language"))
        shot("02-models", onboardingState(.models))
        // CLEANUP-EXPLAINED: the cleanup pick opened, with what it does.
        shot("02-models-change-cleanup", onboardingState(.models), editing: .cleanup)
        let micStep = onboardingState(.microphone, accepted: true)
        micStep.modelDownloads[micStep.onboarding?.picks?.speechID ?? ""] = 0.42
        micStep.onboarding?.extrasQueued = true
        shot("03-mic", micStep)
        shot("04-auto-paste", onboardingState(.autoPaste, accepted: true))
        shot("05-words-empty", onboardingState(.wordsAndSnippets, accepted: true))
        shot("05-words-filled", withWords(onboardingState(.wordsAndSnippets, accepted: true)))
        let tryReadyWords = withWords(onboardingState(.tryIt, accepted: true))
        tryReadyWords.isMicrophoneAuthorized = true
        tryReadyWords.isModelReady = true
        tryReadyWords.selectedModelID = tryReadyWords.onboarding?.picks?.speechID ?? tryReadyWords.selectedModelID
        shot("06-try-it-say-this", tryReadyWords)
        let tryIt = withWords(onboardingState(.tryIt, accepted: true))
        tryIt.isMicrophoneAuthorized = true
        tryIt.isModelReady = true
        tryIt.selectedModelID = tryIt.onboarding?.picks?.speechID ?? tryIt.selectedModelID
        tryIt.transcriptHistory = [TranscriptEntry(text: L10n.tr("%@, here is %@.", word.canonical, snippet.expansion), date: Date())]
        shot("06-try-it-worked", tryIt)
        guard full else { return }

        // WORDS AND SNIPPETS: typed with problems, and half done.
        shot("05-words-problems", onboardingState(.wordsAndSnippets, accepted: true), words: OnboardingWordsPreview(
            canonical: "YappYapp", variants: "", trigger: "email", expansion: snippet.expansion,
            wordIssue: OnboardingWords.wordIssue(canonical: "YappYapp", variantsText: "", existing: Glossary.defaultEntries),
            snippetIssue: OnboardingWords.snippetIssue(trigger: "email", expansion: snippet.expansion, existing: [], glossary: Glossary.defaultEntries)
        ))
        let half = onboardingState(.wordsAndSnippets, accepted: true)
        half.onboarding?.addedWord = word
        shot("05-words-half", half, words: OnboardingWordsPreview(trigger: snippet.trigger))
        // TRY IT: the word came out right but the snippet did not fire.
        let missed = withWords(onboardingState(.tryIt, accepted: true))
        missed.isMicrophoneAuthorized = true
        missed.isModelReady = true
        missed.selectedModelID = missed.onboarding?.picks?.speechID ?? missed.selectedModelID
        missed.transcriptHistory = [TranscriptEntry(text: L10n.tr("%@, here is %@.", word.canonical, L10n.tr("my e-mail")), date: Date())]
        shot("06-try-it-snippet-missed", missed)
        let plain = onboardingState(.tryIt, accepted: true)
        plain.isMicrophoneAuthorized = true
        plain.isModelReady = true
        plain.selectedModelID = plain.onboarding?.picks?.speechID ?? plain.selectedModelID
        plain.transcriptHistory = [TranscriptEntry(text: "So the plan for Monday is to ship the beta and send the invite on Tuesday.", date: Date())]
        shot("06-try-it-worked-no-words", plain)

        // LANGUAGES with picks, and a language outside Parakeet's 25.
        shot("01-languages-picked", onboardingState(.languages, spoken: ["fr", "ja"], translateTarget: .en, profile: nil))
        // DETECT BEST MODELS: scanning, Chinese on a big Mac, an 8 GB Mac
        // with translation on, a pick opened for a change, downloads off,
        // and after USE THESE.
        shot("02-models-scanning", onboardingState(.models, profile: nil))
        shot("02-models-chinese", onboardingState(.models, spoken: ["zh", "en"]))
        shot("02-models-8gb-translate", onboardingState(.models, spoken: ["nl"], translateTarget: .en, profile: m1Base))
        shot("02-models-change-speech", onboardingState(.models), editing: .speech)
        shot("02-models-change-speech-open", onboardingState(.models), editing: .speech, dropdownOpen: L10n.tr("Speech model"))
        let downloadsOff = onboardingState(.models)
        downloadsOff.config.allowModelDownloads = false
        shot("02-models-downloads-off", downloadsOff)
        let accepted = onboardingState(.models, accepted: true)
        accepted.modelDownloads[accepted.onboarding?.picks?.speechID ?? ""] = 0.42
        accepted.onboarding?.extrasQueued = true
        shot("02-models-accepted", accepted)
        // MIC: blocked, then allowed.
        let denied = onboardingState(.microphone, accepted: true)
        denied.isMicrophoneDenied = true
        shot("03-mic-denied", denied)
        let allowed = onboardingState(.microphone, accepted: true)
        allowed.isMicrophoneAuthorized = true
        shot("03-mic-allowed", allowed)
        // AUTO-PASTE: waiting on System Settings, an old grant, offline.
        let waiting = onboardingState(.autoPaste, accepted: true)
        waiting.onboarding?.accessibilityRequested = true
        waiting.modelDownloads[waiting.onboarding?.picks?.speechID ?? ""] = 0.87
        shot("04-auto-paste-waiting", waiting)
        let stale = onboardingState(.autoPaste, accepted: true)
        stale.staleAccessibility = .suspected(.grantDidNotStick)
        shot("04-auto-paste-stale", stale)
        let offline = onboardingState(.autoPaste, accepted: true)
        offline.modelDownloadErrors[offline.onboarding?.picks?.speechID ?? ""] = DownloadErrorCopy.offline
        shot("04-auto-paste-offline", offline)
        // TRY IT: still downloading, and ready before the first dictation.
        let tryWaiting = onboardingState(.tryIt, accepted: true)
        tryWaiting.isMicrophoneAuthorized = true
        tryWaiting.modelDownloads[tryWaiting.onboarding?.picks?.speechID ?? ""] = 0.64
        shot("06-try-it-downloading", tryWaiting)
        let tryReady = onboardingState(.tryIt, accepted: true)
        tryReady.isMicrophoneAuthorized = true
        tryReady.isModelReady = true
        tryReady.selectedModelID = tryReady.onboarding?.picks?.speechID ?? tryReady.selectedModelID
        shot("06-try-it-ready", tryReady)
        // LARGER text: the step body scrolls, the footer stays put.
        let larger = onboardingState(.models)
        larger.config.textSize = BrutalTextSize.larger.rawValue
        shot("02-models-text-larger", larger)
    }

    // MARK: - Indicator

    /// Bottom, left and right: idle, listening, transcribing, cleaning,
    /// pasted, not pasted, canceled with KEEP, error with RETRY.
    @MainActor
    private static func renderIndicatorStates(into gallery: inout Gallery) {
        let failedMessage = DictationFailurePresenter.message(for: WhisperError.timedOut, audioKept: true)
        let secure = PasteOutcomePresenter.status(for: .withheld(.secureInputActive)).phase
        let levels: [Double] = (0..<YappYappState.levelSampleCount).map { index in
            0.15 + 0.6 * abs(sin(Double(index) * 0.55))
        }
        let states: [(String, (YappYappState) -> Void)] = [
            ("idle", { _ in }),
            ("listening", { $0.phase = .recording; $0.levelHistory = levels }),
            ("transcribing", { $0.phase = .transcribing }),
            ("cleaning", { $0.phase = .transcribing; $0.hudNote = CleanupMode.clean.hudNote }),
            ("pasted", { $0.phase = .pasted; $0.pastedElapsedLabel = "0.8s" }),
            ("not-pasted", { $0.phase = secure }),
            ("canceled-keep", { $0.phase = .canceled }),
            ("error-retry", { $0.phase = .error(failedMessage); $0.retryAvailable = true })
        ]
        for position in ["bottom", "top", "left", "right"] {
            for (index, entry) in states.enumerated() {
                let state = readyState()
                state.config.hudPosition = position
                entry.1(state)
                gallery.hud(String(format: "en-ind-%@-%02d-%@", position, index, entry.0), state)
            }
        }
    }

    // MARK: - Localized

    @MainActor
    private static func renderLocalized(_ language: String, into gallery: inout Gallery) {
        let ready = readyState()
        ready.config.appLanguage = language
        gallery.popover("\(language)-home", popover(ready))
        gallery.body("\(language)-home-full", popover(ready).homeTab)
        gallery.popover("\(language)-setup", popover(ready, tab: .settings))
        // CLEANUP-EXPLAINED: the picker with each mode's line and example.
        for mode in CleanupMode.allCases {
            gallery.body("\(language)-setup-cleanup-\(mode.rawValue)", CleanupSettingsControl(
                mode: .constant(mode), readiness: mode.usesModel ? .ready : .off, onDownload: {}, onCancel: {}
            ))
        }
        // NUMBERS: each choice with its line and example.
        for style in NumberStyle.allCases {
            gallery.body("\(language)-setup-numbers-\(style.rawValue)", NumberSettingsControl(style: .constant(style)))
        }
        gallery.body("\(language)-setup-full", popover(ready, tab: .settings).settingsTab)
        // The longest labels at the largest text size.
        gallery.body("\(language)-setup-larger-full", popover(ready, tab: .settings).settingsTab, textSize: BrutalTextSize.larger.rawValue)

        renderLearnFromFixes(language, into: &gallery)

        let fresh = freshState()
        fresh.config.appLanguage = language
        gallery.popover("\(language)-home-fresh-install", popover(fresh))
        // ONBOARDING: a full walk-through in French, the main steps elsewhere.
        renderOnboarding(language, into: &gallery, full: language == "fr")

        let recording = readyState(phase: .recording)
        recording.config.appLanguage = language
        recording.recordingSeconds = Int(recording.config.maxRecordingSeconds) - 7
        gallery.hud("\(language)-hud-recording", recording)

        // MODELS (round 2): scan card and TRANSLATION family, and the
        // TRANSLATE TO row, for overflow checks.
        let scanned = modelsRound2State()
        scanned.config.appLanguage = language
        gallery.body("\(language)-models-scan-full", popover(scanned, tab: .models).modelsTab)
        scanned.config.textSize = BrutalTextSize.larger.rawValue
        gallery.body("\(language)-models-scan-larger-full", popover(scanned, tab: .models).modelsTab.environment(\.brutalTextSize, .larger))
        gallery.body("\(language)-setup-translate-larger-full", popover(scanned, tab: .settings).settingsTab.environment(\.brutalTextSize, .larger))
        gallery.popover("\(language)-models-scan-larger", popover(scanned, tab: .models))
        // QWEN3-ASR family open, and its SETUP captions.
        let qwen = qwen3ASRState()
        qwen.config.appLanguage = language
        gallery.body("\(language)-models-qwen3asr-full", popover(qwen, tab: .models).modelsTab)
        gallery.body("\(language)-setup-qwen3asr-full", popover(qwen, tab: .settings).settingsTab)

        // Models, Words and Pet, for overflow checks.
        for tab in [BrutalTab.files, .models, .words, .pet] {
            gallery.popover("\(language)-tab-\(tab.rawValue.lowercased())", popover(ready, tab: tab))
        }
        // Outcome chips are the longest indicator words in every language.
        let pasted = readyState(phase: .pasted)
        pasted.pastedElapsedLabel = "0.8s"
        gallery.hud("\(language)-hud-pasted", pasted)
        gallery.hud("\(language)-hud-not-pasted", readyState(phase: PasteOutcomePresenter.status(for: .withheld(.secureInputActive)).phase))
        gallery.hud("\(language)-hud-copied-only", readyState(phase: PasteOutcomePresenter.status(for: .copiedOnly(.focusUnclear)).phase))
        gallery.hud("\(language)-hud-canceled", readyState(phase: .canceled))
    }

    // MARK: - States

    @MainActor
    private static func readyState(phase: CapturePhase = .idle) -> YappYappState {
        let state = SelfTests.makeUIState(phase: phase)
        state.statusText = L10n.tr("Pasted at your cursor.")
        state.config.hasCompletedGuidedSetup = true
        state.isMicrophoneAuthorized = true
        state.petStats.totalDictations = 120
        return state
    }

    @MainActor
    private static func freshState() -> YappYappState {
        let state = YappYappState()
        state.config.hasCompletedGuidedSetup = false
        state.isModelReady = false
        state.isWhisperReady = true
        state.isAccessibilityTrusted = false
        state.isMicrophoneAuthorized = false
        state.glossaryEntries = Glossary.defaultEntries
        // The real launch prompt, which MIC swaps out while setup is open.
        state.statusText = StatusFlavor.line(from: StatusFlavor.idlePrompt, index: 0)
        return state
    }

    @MainActor
    private static func popover(
        _ state: YappYappState,
        tab: BrutalTab = .home,
        wordsMode: WordsMode = .words,
        glossaryDrafts: [GlossaryEntryDraft]? = nil
    ) -> BrutalistPopoverView {
        BrutalistPopoverView(
            state: state,
            onToggleRecording: {}, onSelectModel: { _ in }, onDownloadModel: { _ in },
            onCancelDownload: { _ in }, onSaveConfig: { _ in }, onSaveGlossary: { _ in },
            onRequestAccessibility: {}, onResetAndRegrantAccessibility: {},
            onRequestMicrophone: {}, onOpenMicrophoneSettings: {},
            onSetLaunchAtLogin: { _ in }, onChooseStarter: { _ in },
            onEquipAccessory: { _ in }, onSaveRecap: {}, onCopyText: { _ in },
            onRevealSupport: {}, onQuit: {},
            tab: tab,
            configDraft: state.config,
            glossaryDrafts: glossaryDrafts ?? state.glossaryEntries.map(GlossaryEntryDraft.init),
            wordsMode: wordsMode,
            snippetDrafts: state.snippets.map(SnippetDraft.init(snippet:))
        )
    }

    @MainActor
    private static func body(of popover: BrutalistPopoverView, tab: BrutalTab) -> AnyView {
        switch tab {
        case .home: AnyView(popover.homeTab)
        case .files: AnyView(popover.filesTab)
        case .models: AnyView(popover.modelsTab)
        case .words: AnyView(popover.wordsTab)
        case .pet: AnyView(popover.petTab)
        case .settings: AnyView(popover.settingsTab)
        }
    }

    // MARK: - Output

    private struct Gallery {
        let directory: URL
        var written = 0
        var failures: [String] = []

        /// The popover exactly as it appears: 440 x 596, tab body clipped.
        @MainActor
        mutating func popover(
            _ name: String, _ view: BrutalistPopoverView, onboardingEditing: RecommendationKind? = nil,
            dropdownOpen: String? = nil, wordsPreview: OnboardingWordsPreview? = nil
        ) {
            write(name, view
                .environment(\.brutalFlattensScroll, true)
                .environment(\.onboardingInitialEditing, onboardingEditing)
                .environment(\.brutalDropdownForcedOpen, dropdownOpen)
                .environment(\.onboardingWordsPreview, wordsPreview)
                .frame(width: 440, height: 596))
        }

        /// A tab body at popover width and its natural height, so content
        /// below the fold is visible too.
        @MainActor
        mutating func body<V: View>(_ name: String, _ view: V, textSize: String? = nil, dropdownOpen: String? = nil) {
            // A tab body pulled out of the popover misses the popover's text
            // size, so pass it in again.
            write(name, view
                .environment(\.brutalDropdownForcedOpen, dropdownOpen)
                .brutalDropdownHost()
                .environment(\.brutalTextSize, BrutalTextSize(configValue: textSize ?? ""))
                .environment(\.brutalFlattensScroll, true)
                .padding(.horizontal, 18)
                .frame(width: 440)
                .fixedSize(horizontal: false, vertical: true)
                .background(Brutal.paper))
        }

        /// The always-on HUD window content at its real window size.
        @MainActor
        mutating func hud(_ name: String, _ state: YappYappState) {
            let size = AlwaysOnHUDView.windowSize(for: state.config.hudPosition)
            write(name.hasSuffix("-hud") ? name : "\(name)-hud", AlwaysOnHUDView(state: state)
                .environment(\.brutalTextSize, BrutalTextSize(configValue: state.config.textSize))
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.55)))
        }

        @MainActor
        private mutating func write<V: View>(_ name: String, _ view: V) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                failures.append(name)
                return
            }
            do {
                try png.write(to: directory.appendingPathComponent("\(name).png"))
                written += 1
            } catch {
                failures.append("\(name): \(error)")
            }
        }
    }
}
#endif
