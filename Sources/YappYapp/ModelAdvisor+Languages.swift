import Foundation

// ONBOARDING: the languages someone dictates in steer the speech pick. The
// default model stays whenever it covers every language asked for (or this
// table does not know what it covers). Otherwise the first catalog model that
// covers them all and fits this Mac takes over, so a Japanese or Chinese
// speaker never lands on a model that cannot hear them. Pure and unit tested.

/// Which spoken languages a speech model understands.
enum SpeechLanguageCoverage: Equatable, Sendable {
    /// Whisper's multilingual models: about 100 languages.
    case all
    case only(Set<String>)
    /// A model this table does not describe. Never ruled out by language.
    case unknown

    /// nil when unknown.
    func covers(_ languages: Set<String>) -> Bool? {
        switch self {
        case .all: true
        case .only(let codes): languages.isSubset(of: codes)
        case .unknown: nil
        }
    }
}

enum SpeechLanguages {
    /// Parakeet TDT v3 (and Ultra, its retrain), from the NVIDIA model card.
    static let parakeetV3: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]

    /// Qwen3-ASR's 30 languages, from the Qwen model card (its 22 Chinese
    /// dialects all fall under "zh" here).
    static let qwen3ASR: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi",
        "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu",
        "mk", "ro"
    ]
}

extension ModelOption {
    var languageCoverage: SpeechLanguageCoverage {
        // Engines added later fall through to unknown, so they are never
        // ruled out by a table that does not know them.
        if engine == .whisper {
            return filename.hasSuffix(".en.bin") ? .only(["en"]) : .all
        }
        if engine == .parakeet {
            switch parakeetVariant ?? "v3" {
            case "v3", "ultra": return .only(SpeechLanguages.parakeetV3)
            case "v2", "tdtCtc110m": return .only(["en"])
            case "tdtJa": return .only(["ja"])
            default: return .unknown
            }
        }
        if engine == .qwen3asr {
            return .only(SpeechLanguages.qwen3ASR)
        }
        return .unknown
    }
}

extension ModelAdvisor {
    /// Models above this size are too heavy for an 8 GB Mac. Qwen3-ASR
    /// 0.6B (about 1.02 GB with its audio encoder) still fits; Whisper
    /// Medium (1.5 GB) does not.
    static let heavySpeechModelBytes: Int64 = 1_100_000_000

    /// The speech pick when the languages rule out the default model; nil
    /// when the default covers them (or nothing was asked for).
    static func languageFit(
        _ profile: HardwareProfile,
        installed: InstalledModels,
        prefix: String,
        languages: Set<String>,
        whisperAvailable: Bool,
        qwen3ASRAvailable: Bool = true
    ) -> ModelRecommendation? {
        let wanted = languages.subtracting(["auto"])
        guard !wanted.isEmpty else { return nil }
        let defaultID = ModelCatalog.recommendedID
        guard let defaultOption = ModelCatalog.option(for: defaultID),
              defaultOption.languageCoverage.covers(wanted) == false else { return nil }

        let names = LanguageCatalog.spokenNames(for: wanted)
        func bytes(_ option: ModelOption) -> Int64? {
            installed.speechIDs.contains(option.id) ? nil : option.downloadBytes
        }
        // Qwen3-ASR leads for languages the default misses: it is more
        // accurate than Whisper on them and stays warm. The 1.7B goes first
        // on Macs with room for it.
        let qwen = ModelCatalog.options.filter { $0.engine == .qwen3asr }
            .sorted { ($0.downloadBytes ?? 0) > ($1.downloadBytes ?? 0) }
        let qwenOrder = profile.memoryGB >= 16 ? qwen : qwen.reversed()
        let ordered = qwenOrder + ModelCatalog.options.filter { $0.engine != .qwen3asr }
        let candidate = ordered.first { option in
            guard option.languageCoverage.covers(wanted) == true else { return false }
            if option.engine == .whisper, !whisperAvailable { return false }
            if option.engine == .qwen3asr, !qwen3ASRAvailable { return false }
            if profile.memoryGB <= 8, (option.downloadBytes ?? 0) > heavySpeechModelBytes { return false }
            return fits(bytes(option), profile: profile)
        }
        guard let candidate else {
            return ModelRecommendation(
                kind: .speech, choice: .speech(modelID: defaultID), title: defaultOption.name,
                reason: prefix + L10n.tr("No model that fits here covers %@. This one covers the rest.", names),
                downloadBytes: bytes(defaultOption)
            )
        }
        return ModelRecommendation(
            kind: .speech, choice: .speech(modelID: candidate.id), title: candidate.name,
            reason: prefix + L10n.tr("Covers %@, which %@ does not.", names, defaultOption.name),
            downloadBytes: bytes(candidate)
        )
    }
}
