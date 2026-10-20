import Foundation

enum CapturePhase: Equatable {
    case idle
    case recording
    case transcribing
    case copied
    case pasted
    // PIPELINE (YA-03): a Cmd+V was sent but nothing confirmed it landed.
    case sentUnconfirmed
    // PIPELINE (YA-03): the transcript did not reach the app. The headline is
    // "COPIED ONLY" or "NOT PASTED"; the reason is a short HUD line.
    case notDelivered(headline: String, reason: String)
    // PIPELINE (YA-19): canceled, audio kept a few seconds for UNDO.
    case canceled
    case error(String)

    var label: String {
        switch self {
        case .idle:
            L10n.tr("Ready")
        case .recording:
            L10n.tr("Listening")
        case .transcribing:
            L10n.tr("Transcribing")
        case .copied:
            L10n.tr("Copied")
        case .pasted:
            L10n.tr("Pasted")
        case .sentUnconfirmed:
            L10n.tr("Pasted?")
        case .notDelivered(let headline, _):
            headline.capitalized
        case .canceled:
            L10n.tr("Canceled")
        case .error:
            L10n.tr("Needs attention")
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            "waveform"
        case .recording:
            "mic.fill"
        case .transcribing:
            "sparkles"
        case .copied:
            "doc.on.clipboard"
        case .pasted:
            "checkmark"
        case .sentUnconfirmed:
            "questionmark"
        case .notDelivered:
            "exclamationmark"
        case .canceled:
            "xmark"
        case .error:
            "exclamationmark.triangle.fill"
        }
    }
}

/// FILES: one finished file transcript, kept in memory for this session.
struct FileTranscriptResult: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let text: String
    let date: Date

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

final class YappYappState: ObservableObject {
    static let levelSampleCount = 48
    static let transcriptHistoryLimit = 10
    static let fileResultsLimit = 10

    @Published var phase: CapturePhase = .idle
    @Published var statusText = StatusFlavor.line(
        from: StatusFlavor.idlePrompt,
        index: Int.random(in: 0..<StatusFlavor.idlePrompt.count)
    )
    @Published var lastTranscript = ""
    @Published var config = AppConfig.defaultConfig
    @Published var glossaryTermCount = 0
    @Published var isWhisperReady = false
    @Published var isModelReady = false
    @Published var isAccessibilityTrusted = false
    // MIC-LIVE-VERIFY: live microphone permission, polled like accessibility so
    // the guided step flips the moment the user grants or revokes access.
    @Published var isMicrophoneAuthorized = false
    @Published var isMicrophoneDenied = false
    // STALE-TCC-DETECT: when non-clean, both popovers reveal the
    // "Still not pasting? Reset the permission" recovery affordance.
    @Published var staleAccessibility: StaleAccessibilityVerdict = .clean
    @Published var isProcessing = false
    @Published var selectedModelID = "parakeet-ultra"
    @Published var selectedModelName = "Parakeet Ultra"
    @Published var modelOptions = ModelCatalog.options
    @Published var glossaryEntries: [GlossaryEntry] = []
    // SNIPPETS: saved spoken phrases and the text they expand to.
    @Published var snippets: [Snippet] = []
    @Published var levelHistory: [Double] = Array(repeating: 0, count: YappYappState.levelSampleCount)
    @Published var recordingSeconds = 0
    @Published var modelDownloads: [String: Double] = [:]
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var launchAtLoginEnabled = false
    // LOGIN-ITEM-APPROVAL (YA-60): registered, but macOS still wants the user
    // to allow it in System Settings > General > Login Items.
    @Published var launchAtLoginNeedsApproval = false
    // MANAGED-PREFS: settings forced by a configuration profile (shown LOCKED).
    @Published var managedConfigKeys: Set<ManagedConfigKey> = []
    // CONFIG-RECOVERY (YA-26): one-time notice after a damaged config.json was repaired.
    @Published var configRecoveryNotice: ConfigRecoveryNotice?
    @Published var transcriptHistory: [TranscriptEntry] = []
    @Published var petStats = PetStats()
    @Published var lastSuccessAt: Date?
    /// 0 = silent, 1 = normal jump, 2 = big double jump, 3 = milestone storm.
    @Published var celebrationIntensity = 1
    // FIRSTRUN track: per-model download failures (plain copy, keyed by model
    // id), a persistent hotkey failure, per-tab inline feedback, and a tab the
    // app asks the open surfaces to show.
    @Published var modelDownloadErrors: [String: String] = [:]
    @Published var hotkeyUnavailable = false
    @Published var tabFeedback: [BrutalTab: TabFeedback] = [:]
    @Published var requestedTab: BrutalTab?
    @Published var activeTab: BrutalTab = .home
    // PIPELINE: a short HUD note such as "TIME LIMIT" (YA-54), and pet news
    // kept apart from the paste outcome so it never overwrites it (YA-29).
    @Published var hudNote: String?
    @Published var petEventNote: String?
    // LEARN-FROM-FIXES: "Learned Genial." with UNDO on the MIC tab.
    @Published var learnedWordNotice: LearnedWordNotice?
    // LLM-CLEANUP (YA-10): runtime and model state for the cleanup mode.
    @Published var cleanupReadiness: CleanupReadiness = .off
    // TRANSLATION (round 2): what the downloadable translation models are
    // doing (verified, downloading, failed). Setup and MODELS derive their
    // captions from it and the config.
    @Published var translationModels = TranslationModelsSnapshot()
    // SCAN MY MAC: the last scan of this Mac and its recommendations.
    @Published var hardwareScan: HardwareScan?
    // ONBOARDING: the first-run flow in progress; nil once finished. The
    // control window and popover show it instead of the tabs.
    @Published var onboarding: OnboardingSession?
    // COMMANDS: a failed dictation's audio is kept, so the HUD and the MIC
    // tab can offer RETRY.
    @Published var retryAvailable = false
    // PROFILES: language, model and profile of the dictation on the HUD.
    // nil shows the Setup values.
    @Published var dictationBadge: DictationBadge?
    // LIVEFILE: the words heard so far while recording (memory only, never
    // pasted), and the drag-and-drop / menu file job shown on the FILES tab.
    // FILES state is kept apart from MIC: a file job never writes phase,
    // statusText, isProcessing, lastTranscript or transcriptHistory.
    @Published var livePreviewText: String?
    @Published var fileTranscription: FileTranscriptionStatus?
    /// FILES: finished file transcripts, newest first. Memory only.
    @Published var fileResults: [FileTranscriptResult] = []
    /// DELIVERY-TRAIL: the last 20 deliveries for the support report.
    /// Memory only, never the transcript, and not published: nothing on
    /// screen redraws for it.
    var deliveryTrail = DeliveryTrail()
    /// How long the last confirmed paste took, e.g. "0.8s", for the
    /// indicator's DONE IN caption. Nil for anything but a timed confirmed paste.
    @Published var pastedElapsedLabel: String?

    /// The selected pet, but only if it is actually unlocked; otherwise none.
    var activePet: PetKind {
        guard let kind = PetKind(rawValue: config.pet), petStats.isUnlocked(kind) else {
            return .none
        }
        return kind
    }

    /// In-memory only: history is intentionally never written to disk and
    /// clears when the app quits.
    func recordFileResult(fileName: String, text: String) {
        fileResults.insert(FileTranscriptResult(fileName: fileName, text: text, date: Date()), at: 0)
        if fileResults.count > Self.fileResultsLimit {
            fileResults.removeLast()
        }
    }

    func recordTranscript(_ text: String) {
        transcriptHistory.insert(TranscriptEntry(text: text, date: Date()), at: 0)
        if transcriptHistory.count > Self.transcriptHistoryLimit {
            transcriptHistory.removeLast()
        }
    }

    func pushLevel(_ level: Double) {
        var history = levelHistory
        history.removeFirst()
        history.append(level)
        levelHistory = history
    }

    func resetLevels() {
        levelHistory = Array(repeating: 0, count: Self.levelSampleCount)
        recordingSeconds = 0
    }
}
