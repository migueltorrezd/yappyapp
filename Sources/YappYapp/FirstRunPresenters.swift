import AppKit

// FIRSTRUN track: small pure presenters for the setup, header, HUD and
// settings copy. Kept apart from the views so the self-tests can walk every
// branch without rendering anything.

// MARK: - YA-33 header chip

struct HeaderChip: Equatable {
    enum Tone: Equatable {
        case idle
        case setup
        case recording
        case transcribing
        case success
        /// YA-03: sent, but the target app could not confirm it arrived.
        case unconfirmed
        case error
    }

    let label: String
    let tone: Tone
}

/// UX-WRITING: one readiness verdict that the header chip, the MIC headline
/// and the green banner all read, so they never disagree.
enum HomeReadiness: Equatable {
    /// Nothing left to do.
    case ready
    /// Dictation works, but a setup step is still open (auto-paste, for one).
    case almostReady
    /// Dictation cannot start yet: no voice model, no mic, or Whisper can't run.
    case notReady

    static func evaluate(canDictate: Bool, setupIncomplete: Bool) -> HomeReadiness {
        guard canDictate else { return .notReady }
        return setupIncomplete ? .almostReady : .ready
    }

    /// The mic opens and a model is there to transcribe.
    static func canDictate(isWhisperReady: Bool, isModelReady: Bool, isMicrophoneAuthorized: Bool) -> Bool {
        isWhisperReady && isModelReady && isMicrophoneAuthorized
    }
}

enum HeaderChipPresenter {
    /// The chip tells the truth about setup: an idle app that cannot dictate
    /// yet says NOT READY, never READY. It never says SET UP, which reads as
    /// a link to the SETUP tab.
    static func chip(phase: CapturePhase, readiness: HomeReadiness) -> HeaderChip {
        switch phase {
        case .idle:
            switch readiness {
            case .ready: HeaderChip(label: L10n.tr("READY"), tone: .idle)
            case .almostReady: HeaderChip(label: L10n.tr("ALMOST READY"), tone: .setup)
            case .notReady: HeaderChip(label: L10n.tr("NOT READY"), tone: .setup)
            }
        case .recording:
            HeaderChip(label: phase.label.uppercased(), tone: .recording)
        case .transcribing:
            HeaderChip(label: phase.label.uppercased(), tone: .transcribing)
        case .copied, .pasted:
            HeaderChip(label: phase.label.uppercased(), tone: .success)
        case .sentUnconfirmed:
            HeaderChip(label: phase.label.uppercased(), tone: .unconfirmed)
        case .notDelivered, .error:
            HeaderChip(label: phase.label.uppercased(), tone: .error)
        case .canceled:
            HeaderChip(label: phase.label.uppercased(), tone: .idle)
        }
    }
}

/// UX-WRITING (P1): the MIC tab has one attention slot under the record
/// block. At most one of these shows, in this order.
enum HomeAttention: Hashable {
    /// A setup step: voice model, mic, auto-paste during first run.
    case setup
    /// A failed dictation, with RETRY inside it when the audio was kept.
    case error(String)
    /// The dictation shortcut could not be registered.
    case shortcutTaken
    /// Auto-paste is on but macOS has not allowed it yet.
    case autoPaste
}

enum HomeScreenPresenter {
    static func attention(
        phase: CapturePhase,
        hasSetupRows: Bool,
        hotkeyUnavailable: Bool,
        autoPasteNotAllowed: Bool
    ) -> HomeAttention? {
        if hasSetupRows { return .setup }
        if case .error(let message) = phase { return .error(message) }
        if hotkeyUnavailable { return .shortcutTaken }
        if autoPasteNotAllowed { return .autoPaste }
        return nil
    }

    /// The green READY banner: idle, fully set up, nothing to flag.
    static func showsReadyBanner(phase: CapturePhase, attention: HomeAttention?) -> Bool {
        phase == .idle && attention == nil
    }

    static func readyBannerTitle(autoPaste: Bool) -> String {
        autoPaste
            ? L10n.tr("READY. TEXT PASTES AT YOUR CURSOR.")
            : L10n.tr("READY. TEXT IS COPIED, THEN YOU PRESS ⌘V.")
    }

    /// The record block headline is the phase. The mode wording (PRESS TO
    /// TALK, HOLD TO TALK, TAP OR HOLD) only shows when idle and ready.
    static func headline(
        phase: CapturePhase,
        canDictate: Bool,
        isCleaning: Bool,
        mode: RecordingMode
    ) -> String {
        switch phase {
        case .idle:
            canDictate ? mode.headline : L10n.tr("NOT READY YET")
        case .recording:
            L10n.tr("LISTENING")
        case .transcribing:
            isCleaning ? L10n.tr("CLEANING UP") : L10n.tr("TRANSCRIBING")
        case .pasted:
            L10n.tr("PASTED")
        case .copied:
            L10n.tr("COPIED")
        case .sentUnconfirmed:
            L10n.tr("PASTED?")
        case .notDelivered(let headline, _):
            headline
        case .canceled:
            L10n.tr("CANCELED")
        case .error:
            canDictate ? L10n.tr("DIDN'T WORK") : L10n.tr("NOT READY YET")
        }
    }

    /// CLEANING UP: the transcribing phase while the HUD shows a cleanup
    /// mode's note. Compared to the notes themselves, so it holds in every
    /// language and for a per-app profile's mode.
    static func isCleaning(phase: CapturePhase, hudNote: String?) -> Bool {
        guard phase == .transcribing, let hudNote else { return false }
        return CleanupMode.allCases.contains { $0.usesModel && $0.hudNote == hudNote }
    }

    /// The line under the headline. nil hides it because the attention slot
    /// already says the same thing. An idle prompt that promises the
    /// shortcut is swapped out while dictation can't start or the shortcut
    /// is dead.
    static func statusLine(
        statusText: String,
        phase: CapturePhase,
        attention: HomeAttention?,
        canDictate: Bool,
        shortcutFailureText: String?
    ) -> String? {
        if case .error(let message) = attention, statusText == message { return nil }
        let isIdlePrompt = StatusFlavor.idlePrompt.contains(statusText)
        if phase == .idle, !canDictate, isIdlePrompt {
            return L10n.tr("Finish the step below, then ⌥ space works in any app.")
        }
        if attention == .shortcutTaken, isIdlePrompt || statusText == shortcutFailureText {
            return nil
        }
        return statusText
    }

    /// The error banner's detail. With RETRY in the banner, the menu path
    /// in the failure message is replaced by a plain fact.
    static func errorDetail(message: String, retryOffered: Bool) -> String {
        guard retryOffered else { return message }
        let base = message
            .replacingOccurrences(of: DictationFailurePresenter.retryHint, with: "")
            .trimmingCharacters(in: .whitespaces)
        let kept = L10n.tr("Your audio is kept.")
        return base.isEmpty ? kept : "\(base) \(kept)"
    }

    /// TIPS wait until first run is done, so setup has the screen to itself.
    static func showsTips(guidedSetupDone: Bool) -> Bool {
        guidedSetupDone
    }

    /// The first-run mic check comes after the mic step, never before the
    /// voice model is there.
    static func showsGuidedMicCheck(canTranscribe: Bool) -> Bool {
        canTranscribe
    }
}

// MARK: - YA-75 HUD labels

enum HUDLabelPresenter {
    static func trailingLabel(phase: CapturePhase, recordingSeconds: Int) -> String {
        switch phase {
        case .recording:
            String(format: "%d:%02d", recordingSeconds / 60, recordingSeconds % 60)
        case .transcribing:
            L10n.tr("TRANSCRIBING")
        case .pasted:
            L10n.tr("PASTED")
        case .copied:
            L10n.tr("COPIED")
        case .sentUnconfirmed:
            L10n.tr("PASTED?")
        case .notDelivered(let headline, _):
            headline
        case .canceled:
            L10n.tr("KEEP")
        case .error(let message):
            message.hasPrefix(MissingModelNotice.messagePrefix) ? MissingModelNotice.hudLabel : PasteOutcomePresenter.genericErrorLabel
        case .idle:
            L10n.tr("READY")
        }
    }
}

// MARK: - YA-35 auto-paste prompt

enum AutoPastePrompt {
    /// One prompt only. During the wizard the numbered step asks; after it,
    /// the banner asks on every tab and the setup list leaves it out. Nothing
    /// asks when the user chose copy-only.
    static func showsBanner(
        accessibilityTrusted: Bool,
        autoPasteEnabled: Bool,
        isGuidedFirstRun: Bool
    ) -> Bool {
        !accessibilityTrusted && autoPasteEnabled && !isGuidedFirstRun
    }

    static func bannerDetail(isStale: Bool) -> String {
        isStale
            ? L10n.tr("macOS remembers an older YappYapp. Click RESET, then turn YappYapp on again in Accessibility.")
            : L10n.tr("Your text is copied, not pasted. Click ALLOW so it pastes at your cursor.")
    }

    static func bannerActionTitle(isStale: Bool) -> String {
        isStale ? L10n.tr("RESET") : L10n.tr("ALLOW")
    }

    static var bannerTitle: String { L10n.tr("AUTO-PASTE NOT ALLOWED YET") }

    static var firstTimeDetail: String { L10n.tr("So your text pastes at your cursor. Click ALLOW, then turn on YappYapp in System Settings > Privacy & Security > Accessibility.") }
}

// MARK: - YA-24 / YA-25 engine notes

struct EngineSettingsNotes: Equatable {
    /// SETUP > DICTATION: one caption for what the selected model
    /// ignores (dictation language, translate). nil when both apply.
    let languageAndTranslate: String?
    /// SETUP > MICROPHONE, under QUIET VOICE BOOST.
    let quietVoiceBoost: String?

    static func notes(for config: AppConfig) -> EngineSettingsNotes {
        let selectedID = ModelCatalog.selectedID(for: config.modelPath)
        let option = ModelCatalog.option(for: selectedID)
        let englishOnly = option.map(ModelActivationPlanner.forcesEnglishLanguage) ?? false

        // QWEN3-ASR detects the language on AUTO and takes a picked one as a
        // hint. It has no beam search, so the boost only lifts the meter.
        if ModelCatalog.engine(for: config.modelPath) == .qwen3asr {
            return EngineSettingsNotes(
                languageAndTranslate: L10n.tr("Qwen3-ASR picks the language itself on AUTO. Pick a language to steer it."),
                quietVoiceBoost: L10n.tr("Lifts quiet speech for Whisper models. With Qwen3-ASR, only the level meter changes.")
            )
        }

        guard ModelCatalog.engine(for: config.modelPath) == .parakeet else {
            return EngineSettingsNotes(
                languageAndTranslate: englishOnly
                    ? L10n.tr("This model only does English. Your language pick is kept for other models.")
                    : nil,
                quietVoiceBoost: nil
            )
        }

        // Parakeet ignores the language setting. Translation (TRANSLATE TO)
        // runs after it, so it no longer belongs in this caption.
        let languageAndTranslate: String
        if englishOnly {
            languageAndTranslate = L10n.tr("This model only does English. Your language pick is kept for other models.")
        } else if option?.parakeetVariant == "tdtJa" {
            languageAndTranslate = L10n.tr("This model is built for Japanese. Dictation language changes Whisper and Qwen3-ASR models.")
        } else {
            languageAndTranslate = L10n.tr("Parakeet picks the language itself. Dictation language changes Whisper and Qwen3-ASR models.")
        }

        return EngineSettingsNotes(
            languageAndTranslate: languageAndTranslate,
            quietVoiceBoost: L10n.tr("Lifts quiet speech for Whisper models. With Parakeet, only the level meter changes.")
        )
    }

    /// Whether Whisper's built-in translate mode can run with the selected
    /// model. Any other translation runs after transcription, on any engine.
    static func translateApplies(for config: AppConfig) -> Bool {
        ModelCatalog.engine(for: config.modelPath) == .whisper
    }

    static func menuLanguageTitle(for config: AppConfig) -> String {
        ModelCatalog.engine(for: config.modelPath) == .parakeet
            ? L10n.tr("Dictation Language (Not for Parakeet)")
            : L10n.tr("Dictation Language")
    }

    static func menuLanguageStatus(label: String, config: AppConfig) -> String {
        let effective = TranscriptionLanguage.effectiveLanguage(for: config)
        if ModelCatalog.engine(for: config.modelPath) == .parakeet {
            return L10n.tr("Dictation language set to %@. Parakeet picks the language itself, so this changes Whisper and Qwen3-ASR models.", label)
        }
        if effective != config.language {
            return L10n.tr("Dictation language set to %@. This model only does English.", label)
        }
        return L10n.tr("Dictation language: %@.", label)
    }
}

// MARK: - YA-34 plain download errors

enum DownloadErrorCopy {
    static func plain(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return plain(urlErrorCode: urlError.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return plain(urlErrorCode: nsError.code)
        }
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return diskFull
        }
        return plain(message: error.localizedDescription)
    }

    static var offline: String { L10n.tr("No internet connection. Connect and try again.") }
    static var timedOut: String { L10n.tr("The connection is too slow or dropped. Try again.") }
    static var serverBusy: String { L10n.tr("Hugging Face is busy right now. Try again in a few minutes.") }
    static var diskFull: String { L10n.tr("Not enough disk space. Free some space and try again.") }
    static var integrity: String { L10n.tr("The download didn't verify, so it was deleted. Try again.") }
    static var generic: String { L10n.tr("The download stopped. Try again.") }

    static func plain(urlErrorCode code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            offline
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
            timedOut
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            L10n.tr("Could not reach Hugging Face. Check your connection, VPN or firewall and try again.")
        case NSURLErrorCannotWriteToFile:
            diskFull
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            L10n.tr("A secure connection to Hugging Face failed. A network filter may be in the way.")
        default:
            generic
        }
    }

    static func plain(message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("mismatch") || lowered.contains("missing model files") {
            return integrity
        }
        if lowered.contains("rate limit") || lowered.contains("http 429") || lowered.contains("http 503") {
            return serverBusy
        }
        if lowered.contains("space") && lowered.contains("disk") {
            return diskFull
        }
        if lowered.contains("http ") {
            return L10n.tr("The download server refused the request. Try again later.")
        }
        return generic
    }

    static func status(optionName: String, plain: String) -> String {
        L10n.tr("Couldn't download %@. %@", optionName, plain)
    }
}

// MARK: - YA-72 hotkey failure

enum HotkeyStatusCopy {
    /// Personalize before uppercasing, so the live shortcut is named.
    static var unavailableTitle: String { L10n.tr("⌥ space is taken") }
    static var unavailableDetail: String { L10n.tr("Another app is using ⌥ space. Pick a new shortcut in Setup > Dictation, or click the mic to dictate.") }
    static var unavailableStatus: String { L10n.tr("⌥ space is taken. Click the mic, or pick a new shortcut in Setup > Dictation.") }

    /// `escCancels` follows the YA-19 setting, so esc is only offered when it works.
    static func listeningStatus(hotkeyAvailable: Bool, escCancels: Bool = true) -> String {
        switch (hotkeyAvailable, escCancels) {
        case (true, true): L10n.tr("Listening. Press ⌥ space to stop, Esc to cancel.")
        case (true, false): L10n.tr("Listening. Press ⌥ space to stop.")
        case (false, true): L10n.tr("Listening. Click the mic to stop, Esc to cancel.")
        case (false, false): L10n.tr("Listening. Click the mic to stop.")
        }
    }

    static func tooltip(hotkeyAvailable: Bool) -> String {
        hotkeyAvailable
            ? L10n.tr("YappYapp (⌥ space to dictate, right-click for menu)")
            : L10n.tr("YappYapp (click to dictate, right-click for menu)")
    }
}

// MARK: - YA-73 Whisper runtime copy

enum WhisperRuntimeCopy {
    /// True for the signed .app (DMG installs). Source builds have no bundle
    /// identifier.
    static var isPackagedApp: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func missingDetail(isPackagedApp: Bool) -> String {
        isPackagedApp
            ? L10n.tr("This copy of YappYapp can't run Whisper models. Pick a Parakeet model in Models, or reinstall from the latest DMG.")
            : L10n.tr("Use the release app, or install with: brew install whisper-cpp")
    }

    static func missingBlockedMessage(isPackagedApp: Bool, binaryPath: String) -> String {
        isPackagedApp
            ? L10n.tr("Whisper models can't run in this copy of YappYapp. Pick a Parakeet model in Models, or reinstall YappYapp.")
            // YA-63: a binary the helper policy refused says why.
            : WhisperError.binaryProblem(for: binaryPath).localizedDescription
    }

    /// The editable whisper-cli path is a developer setting.
    static func showsBinaryPathField(isPackagedApp: Bool) -> Bool {
        !isPackagedApp
    }
}

// MARK: - YA-27 control window on launch

enum ControlWindowLaunchPolicy {
    /// Open on its own only while setup is incomplete or when the user
    /// launched the app by hand. A login launch with setup done stays in the
    /// menu bar.
    static func opensOnLaunch(setupComplete: Bool, launchedAsLoginItem: Bool) -> Bool {
        !setupComplete || !launchedAsLoginItem
    }

    /// The launch Apple event says "launched as login item" through
    /// keyAEPropData = keyAELaunchedAsLogInItem.
    static func isLoginItemLaunch(eventID: UInt32?, propData: UInt32?) -> Bool {
        eventID == UInt32(kAEOpenApplication) && propData == UInt32(keyAELaunchedAsLogInItem)
    }
}

// MARK: - YA-34 / YA-75 model row notes

struct ModelRowStatus: Equatable {
    let text: String
    let isError: Bool

    /// The extra line under a model's summary: why its download failed.
    /// Installed models need none, and "downloads are off" is said once, in
    /// the Models footnote and the row chip.
    static func note(isInstalled: Bool, downloadsAllowed: Bool, downloadError: String?) -> ModelRowStatus? {
        guard !isInstalled, downloadsAllowed, let downloadError else { return nil }
        return ModelRowStatus(text: downloadError, isError: true)
    }
}
