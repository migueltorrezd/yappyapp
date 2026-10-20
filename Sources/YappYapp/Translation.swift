import Foundation

// TRANSLATION (round 2): after transcription and cleanup, a dictation can go
// out in another language. Two ways to do it:
// - Whisper's built-in translate mode, English only and only while a Whisper
//   speech model is in use. No download.
// - A pinned Hy-MT2 translation model (Apache-2.0, tencent) run through the
//   same bundled llama.cpp runtime as cleanup. 33 languages upstream; the app
//   offers the ten below.
// Everything here is pure so the self-tests and unit tests pin it.

/// Pinned Hugging Face revisions and LFS SHA-256 values, read from
/// the Hugging Face model API (api/models/<repo>?blobs=true) on 2026-10-18.
let HyMT2FastPinnedRevision = "a0c709d9fac510f2c807aa3af52872340dc37a4a"
let HyMT2FastPinnedSHA256 = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
let HyMT2BestPinnedRevision = "ab8472660ac61fac25f1af43fac2599d52a8a775"
let HyMT2BestPinnedSHA256 = "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b"

/// The language a dictation is translated into. `off` keeps it as spoken.
enum TranslationTarget: String, CaseIterable, Identifiable, Sendable {
    case off
    case en, fr, es, nl, de, pt, it, ja, zh, ko

    var id: String { rawValue }

    /// Stored value in config.json. Unknown values mean off.
    static func resolve(_ stored: String) -> TranslationTarget {
        TranslationTarget(rawValue: stored) ?? .off
    }

    /// Picker label.
    var label: String {
        switch self {
        case .off: L10n.tr("OFF")
        case .en: L10n.tr("ENGLISH")
        case .fr: L10n.tr("FRENCH")
        case .es: L10n.tr("SPANISH")
        case .nl: L10n.tr("DUTCH")
        case .de: L10n.tr("GERMAN")
        case .pt: L10n.tr("PORTUGUESE")
        case .it: L10n.tr("ITALIAN")
        case .ja: L10n.tr("JAPANESE")
        case .zh: L10n.tr("CHINESE")
        case .ko: L10n.tr("KOREAN")
        }
    }

    /// The full English language name the Hy-MT2 prompt template asks for
    /// (model card: "use the full language names ... English names should be
    /// used in English prompts"). Never localized.
    var promptName: String? {
        switch self {
        case .off: nil
        case .en: "English"
        case .fr: "French"
        case .es: "Spanish"
        case .nl: "Dutch"
        case .de: "German"
        case .pt: "Portuguese"
        case .it: "Italian"
        case .ja: "Japanese"
        case .zh: "Chinese"
        case .ko: "Korean"
        }
    }
}

enum TranslationModelID: String, CaseIterable, Identifiable, Sendable {
    case whisperBuiltIn = "whisper"
    case hyMT2Fast = "hy-mt2-1.8b"
    case hyMT2Best = "hy-mt2-7b"

    var id: String { rawValue }

    /// Stored value in config.json. Unknown values mean the default model.
    static func resolve(_ stored: String) -> TranslationModelID {
        TranslationModelID(rawValue: stored) ?? TranslationCatalog.defaultModelID
    }
}

/// One pinned GGUF on Hugging Face.
struct TranslationDownload: Equatable, Sendable {
    let repo: String
    let revision: String
    let filename: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64
}

struct TranslationModel: Identifiable, Equatable, Sendable {
    let id: TranslationModelID
    let name: String
    /// English key for the badge: FAST, BEST, BUILT IN.
    let badge: String
    /// English key for the one-line summary.
    let summary: String
    /// nil for Whisper's built-in mode, which downloads nothing.
    let download: TranslationDownload?

    var sizeLabel: String? {
        download.map { ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file) }
    }

    func supports(_ target: TranslationTarget) -> Bool {
        switch id {
        case .whisperBuiltIn: target == .en
        case .hyMT2Fast, .hyMT2Best: target != .off
        }
    }
}

enum TranslationCatalog {
    static let defaultModelID = TranslationModelID.hyMT2Fast

    static let models: [TranslationModel] = [
        TranslationModel(
            id: .hyMT2Fast,
            name: "Hy-MT2 1.8B",
            badge: "FAST",
            summary: "10 languages. Quick on any Apple silicon Mac.",
            download: TranslationDownload(
                repo: "tencent/Hy-MT2-1.8B-GGUF",
                revision: HyMT2FastPinnedRevision,
                filename: "Hy-MT2-1.8B-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/\(HyMT2FastPinnedRevision)/Hy-MT2-1.8B-Q4_K_M.gguf")!,
                sha256: HyMT2FastPinnedSHA256,
                sizeBytes: 1_133_080_448
            )
        ),
        TranslationModel(
            id: .hyMT2Best,
            name: "Hy-MT2 7B",
            badge: "BEST",
            summary: "10 languages. Best quality. Wants 24 GB of memory or more.",
            download: TranslationDownload(
                repo: "tencent/Hy-MT2-7B-GGUF",
                revision: HyMT2BestPinnedRevision,
                filename: "Hy-MT2-7B-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/\(HyMT2BestPinnedRevision)/Hy-MT2-7B-Q4_K_M.gguf")!,
                sha256: HyMT2BestPinnedSHA256,
                sizeBytes: 4_624_648_896
            )
        ),
        TranslationModel(
            id: .whisperBuiltIn,
            name: "Whisper",
            badge: "BUILT IN",
            summary: "English only, with a Whisper speech model. Translates as it transcribes.",
            download: nil
        )
    ]

    static func model(_ id: TranslationModelID) -> TranslationModel {
        models.first { $0.id == id } ?? models[0]
    }

    /// Targets the picker offers: every language some offered model supports.
    static var targets: [TranslationTarget] {
        TranslationTarget.allCases.filter { target in
            target == .off || models.contains { $0.supports(target) }
        }
    }
}

// MARK: - Which model does the work

/// What happens to a dictation's language, given the settings.
enum TranslationRoute: Equatable, Sendable {
    case off
    /// whisper.cpp runs with -tr; nothing runs afterwards.
    case whisperBuiltIn
    /// A llama.cpp translation model runs after cleanup.
    case model(TranslationModelID)
}

struct TranslationPlan: Equatable, Sendable {
    let target: TranslationTarget
    let route: TranslationRoute
    /// The user picked Whisper, but it cannot do this target or engine, so
    /// the default translation model stands in. The caption says so.
    let substitutedForWhisper: Bool

    static func make(target: TranslationTarget, chosen: TranslationModelID, engine: ModelEngine) -> TranslationPlan {
        guard target != .off else {
            return TranslationPlan(target: target, route: .off, substitutedForWhisper: false)
        }
        if chosen == .whisperBuiltIn {
            if target == .en, engine == .whisper {
                return TranslationPlan(target: target, route: .whisperBuiltIn, substitutedForWhisper: false)
            }
            return TranslationPlan(target: target, route: .model(TranslationCatalog.defaultModelID), substitutedForWhisper: true)
        }
        return TranslationPlan(target: target, route: .model(chosen), substitutedForWhisper: false)
    }

    var modelID: TranslationModelID? {
        switch route {
        case .off: nil
        case .whisperBuiltIn: .whisperBuiltIn
        case .model(let id): id
        }
    }
}

extension AppConfig {
    var translation: TranslationTarget {
        get { TranslationTarget.resolve(translateTarget) }
        set { translateTarget = newValue.rawValue }
    }

    var translationModelID: TranslationModelID {
        get { TranslationModelID.resolve(translationModel) }
        set { translationModel = newValue.rawValue }
    }

    var translationPlan: TranslationPlan {
        TranslationPlan.make(
            target: translation,
            chosen: translationModelID,
            engine: ModelCatalog.engine(for: modelPath)
        )
    }

    /// whisper.cpp gets -tr only on the built-in route.
    var whisperTranslates: Bool {
        translationPlan.route == .whisperBuiltIn
    }

    /// Config migration: a file from before translation targets carries only
    /// translateToEnglish. On means English, through Whisper when a Whisper
    /// model is active, else through the default translation model.
    static func migratedTranslation(
        storedTarget: String?,
        storedModel: String?,
        legacyTranslateToEnglish: Bool,
        modelPath: String
    ) -> (target: String, model: String) {
        let target = storedTarget.map { TranslationTarget.resolve($0).rawValue }
            ?? (legacyTranslateToEnglish ? TranslationTarget.en.rawValue : TranslationTarget.off.rawValue)
        if let storedModel {
            return (target, TranslationModelID.resolve(storedModel).rawValue)
        }
        let whisperActive = ModelCatalog.engine(for: modelPath) == .whisper
        let model: TranslationModelID = (storedTarget == nil && legacyTranslateToEnglish && whisperActive)
            ? .whisperBuiltIn
            : TranslationCatalog.defaultModelID
        return (target, model.rawValue)
    }
}

// MARK: - Prompt and output (Hy-MT2 model card templates)

enum TranslationPrompt {
    /// Hy-MT2 "Default Translation" template, or its "Terminology" template
    /// when glossary spellings must survive. No system prompt: the model card
    /// says the models have none.
    static func make(text: String, target: TranslationTarget, protectedTerms: [String]) -> String {
        let language = target.promptName ?? "English"
        let terms = LLMCleaner.normalizedProtectedTerms(protectedTerms).prefix(20)
        guard !terms.isEmpty else {
            return "Translate the following text into \(language). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
        let references = terms.map { "\($0) translates to \($0)" }.joined(separator: "\n")
        return "Reference the following translations:\n\(references)\n\nTranslate the following text into \(language). Note that you must ONLY output the translated result without any additional explanation:\n\n\(text)"
    }

    /// Output budget. Translations run about as long as the source; CJK
    /// output can take more tokens per character, so leave room.
    static func tokenBudget(for text: String) -> Int {
        max(256, min(4_096, text.count * 3 / 2))
    }

    /// Hard ceiling, model load included. Past it the untranslated text goes.
    static func hardTimeout(for text: String, model: TranslationModelID) -> TimeInterval {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        switch model {
        case .hyMT2Best: return min(120, 20 + words / 4)
        case .hyMT2Fast, .whisperBuiltIn: return min(45, 10 + words / 12)
        }
    }

    /// Context window: prompt plus a five-minute dictation and its output.
    static let contextTokens = 8_192
}

/// Why a translation was refused even though the model ran.
enum TranslationAcceptance {
    static func isAcceptable(original: String, translated: String) -> Bool {
        let output = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return false }
        // A runaway or an answer instead of a translation.
        guard output.count <= original.count * 4 + 200 else { return false }
        // The model echoed the instructions instead of translating.
        if output.contains("Translate the following text into") { return false }
        return true
    }
}

// MARK: - What the dictation shows when it went out untranslated

enum TranslationFallback: Equatable, Sendable {
    case runtimeMissing
    case modelMissing
    case timedOut
    case failed

    var hudNote: String {
        switch self {
        case .runtimeMissing: L10n.tr("NOT TRANSLATED · CAN'T RUN")
        case .modelMissing: L10n.tr("NOT TRANSLATED · NO MODEL")
        case .timedOut: L10n.tr("NOT TRANSLATED · TOO SLOW")
        case .failed: L10n.tr("NOT TRANSLATED · FAILED")
        }
    }

    var message: String {
        switch self {
        case .runtimeMissing:
            L10n.tr("Sent your words untranslated. This copy of YappYapp can't run translation.")
        case .modelMissing:
            L10n.tr("Sent your words untranslated. The translation model isn't downloaded. See Setup.")
        case .timedOut:
            L10n.tr("Sent your words untranslated. Translation took too long.")
        case .failed:
            L10n.tr("Sent your words untranslated. Translation hit an error.")
        }
    }
}

enum TranslationOutcome: Equatable, Sendable {
    case translated
    case skipped
    case fellBack(TranslationFallback)
}

struct TranslationResult: Equatable, Sendable {
    var text: String
    var outcome: TranslationOutcome

    var fallback: TranslationFallback? {
        if case .fellBack(let reason) = outcome { return reason }
        return nil
    }
}

// MARK: - What Setup says

/// The downloadable models as the app sees them right now.
struct TranslationModelsSnapshot: Equatable, Sendable {
    var verified: Set<TranslationModelID> = []
    var installed: Set<TranslationModelID> = []
    var phases: [TranslationModelID: CleanupDownloadPhase] = [:]
    var runtimeAvailable = true

    func phase(_ id: TranslationModelID) -> CleanupDownloadPhase {
        phases[id] ?? .idle
    }
}

enum TranslationReadiness: Equatable, Sendable {
    case off
    case whisperBuiltIn
    case needsRuntime(TranslationModelID)
    case needsModel(TranslationModelID, downloadsAllowed: Bool)
    case downloading(TranslationModelID, fraction: Double?)
    case verifying(TranslationModelID)
    case failed(TranslationModelID, String)
    case ready(TranslationModelID)

    static func evaluate(plan: TranslationPlan, snapshot: TranslationModelsSnapshot, downloadsAllowed: Bool) -> TranslationReadiness {
        switch plan.route {
        case .off: return .off
        case .whisperBuiltIn: return .whisperBuiltIn
        case .model(let id):
            guard snapshot.runtimeAvailable else { return .needsRuntime(id) }
            if snapshot.verified.contains(id) { return .ready(id) }
            switch snapshot.phase(id) {
            case .downloading(let fraction): return .downloading(id, fraction: fraction)
            case .verifying: return .verifying(id)
            case .failed(let message): return .failed(id, message)
            case .idle: return .needsModel(id, downloadsAllowed: downloadsAllowed)
            }
        }
    }

    var modelID: TranslationModelID? {
        switch self {
        case .off: nil
        case .whisperBuiltIn: .whisperBuiltIn
        case .needsRuntime(let id), .needsModel(let id, _), .downloading(let id, _),
             .verifying(let id), .failed(let id, _), .ready(let id): id
        }
    }

    /// Short uppercase status chip.
    var headline: String {
        switch self {
        case .off: L10n.tr("OFF")
        case .whisperBuiltIn: L10n.tr("BUILT IN")
        case .needsRuntime: L10n.tr("CAN'T RUN HERE")
        case .needsModel(_, let allowed): allowed ? L10n.tr("NOT DOWNLOADED") : L10n.tr("DOWNLOADS OFF")
        case .downloading(_, let fraction):
            fraction.map { L10n.tr("DOWNLOADING %@%%", "\(Int(($0 * 100).rounded(.down)))") } ?? L10n.tr("DOWNLOADING")
        case .verifying: L10n.tr("VERIFYING")
        case .failed: L10n.tr("DOWNLOAD FAILED")
        case .ready: L10n.tr("READY")
        }
    }

    /// One plain caption: which model translates and whether it is here.
    func detail(substitutedForWhisper: Bool) -> String {
        let name = modelID.map { TranslationCatalog.model($0).name } ?? ""
        let size = modelID.flatMap { TranslationCatalog.model($0).sizeLabel } ?? ""
        let body: String
        switch self {
        case .off:
            body = L10n.tr("Your words go out in the language you spoke.")
        case .whisperBuiltIn:
            body = L10n.tr("Whisper translates to English as it transcribes. Nothing to download.")
        case .needsRuntime:
            body = L10n.tr("This copy of YappYapp can't run translation. You get your words untranslated.")
        case .needsModel(_, let allowed):
            body = allowed
                ? L10n.tr("%@ translates on this Mac. It isn't downloaded yet (%@). Until then, you get your words untranslated.", name, size)
                : L10n.tr("%@ translates on this Mac, but it isn't downloaded and downloads are off. Until then, you get your words untranslated.", name)
        case .downloading:
            body = L10n.tr("Downloading %@ (%@). You get your words untranslated until it's done.", name, size)
        case .verifying:
            body = L10n.tr("Verifying %@.", name)
        case .failed(_, let message):
            body = message
        case .ready:
            body = L10n.tr("%@ translates on this Mac. Downloaded and ready.", name)
        }
        guard substitutedForWhisper else { return body }
        return L10n.tr("Whisper only translates to English with a Whisper speech model.") + " " + body
    }

    var canDownload: Bool {
        switch self {
        case .needsModel(_, let allowed): allowed
        case .failed: true
        default: false
        }
    }

    var canCancel: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
