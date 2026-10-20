import Foundation
import IOKit.ps

// SCAN MY MAC (round 2): reads what this Mac is, then recommends one speech
// model, one cleanup mode and one translation model from what the app
// actually offers. The rules are pure (`ModelAdvisor.recommend`) and unit
// tested; reading the hardware lives apart in `HardwareScanner`.
//
// Rules, from llama.cpp Apple Silicon benchmarks (2026-10):
// - 8 GB, any M chip: Parakeet, no Whisper large, small translation model.
// - 16 GB base M1/M2/M3: Parakeet (Whisper Large v3 Turbo for other
//   languages), small translation model.
// - M3 Pro or M4 and newer: the same, and the big translation model only
//   from 24 GB.
// - 24 GB and more on Pro/Max/Ultra: the big translation model.
// - The 7B never on a base M1/M2/M3, whatever the memory.
// - Never a download that would leave less than 5 GB free.
// - QWEN3-ASR: the speech reason also names the Qwen3-ASR size for languages
//   Parakeet does not cover: 1.7B from 16 GB on an M3 Pro/Max/Ultra or any
//   M4 and newer, else 0.6B. It never changes the speech pick.

/// What `HardwareScanner` read. Plain values so tests can build any Mac.
struct HardwareProfile: Equatable, Sendable {
    /// sysctl machdep.cpu.brand_string, such as "Apple M5 Pro".
    var chipName: String
    /// sysctl hw.model, such as "Mac16,7".
    var modelIdentifier: String
    var memoryBytes: Int64
    /// "26.1" style.
    var macOSVersion: String
    var freeDiskBytes: Int64
    var onBattery: Bool

    var memoryGB: Int {
        Int((Double(memoryBytes) / 1_073_741_824).rounded())
    }

    var chip: AppleChip { AppleChip(brandString: chipName) }

    /// "M5 Pro · 48 GB · macOS 26.1 · 210 GB free", plus "on battery".
    var summaryLine: String {
        var parts = [chip.shortName, "\(memoryGB) GB", "macOS \(macOSVersion)", L10n.tr("%@ GB free", "\(freeDiskBytes / 1_000_000_000)")]
        if onBattery { parts.append(L10n.tr("on battery")) }
        return parts.joined(separator: " · ")
    }
}

struct AppleChip: Equatable, Sendable {
    enum Tier: String, Sendable {
        case base, pro, max, ultra, unknown
    }

    /// 1 for M1, 5 for M5. nil when the brand string is not an M chip.
    let generation: Int?
    let tier: Tier
    let shortName: String

    init(brandString: String) {
        let trimmed = brandString.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("Apple ") ? String(trimmed.dropFirst("Apple ".count)) : trimmed
        shortName = name.isEmpty ? "Mac" : name
        let words = name.split(separator: " ").map(String.init)
        if let first = words.first, first.hasPrefix("M"), let number = Int(first.dropFirst()) {
            generation = number
            switch words.dropFirst().first?.lowercased() {
            case nil: tier = .base
            case "pro": tier = .pro
            case "max": tier = .max
            case "ultra": tier = .ultra
            default: tier = .unknown
            }
        } else {
            generation = nil
            tier = .unknown
        }
    }

    /// Pro, Max or Ultra.
    var isHighTier: Bool { tier == .pro || tier == .max || tier == .ultra }
}

enum RecommendationKind: String, CaseIterable, Sendable {
    case speech, cleanup, translation

    var label: String {
        switch self {
        case .speech: L10n.tr("SPEECH")
        case .cleanup: L10n.tr("CLEANUP")
        case .translation: L10n.tr("TRANSLATION")
        }
    }
}

enum RecommendedChoice: Equatable, Sendable {
    case speech(modelID: String)
    case cleanup(CleanupMode)
    case translation(TranslationModelID)
    /// Nothing fits; the reason says why.
    case none
}

struct ModelRecommendation: Equatable, Sendable {
    let kind: RecommendationKind
    let choice: RecommendedChoice
    /// Display name, such as "Parakeet TDT v3" or "Hy-MT2 7B".
    let title: String
    /// One line: "M5 Pro, 48 GB: ...".
    let reason: String
    /// Bytes to download when picked; nil when already on this Mac.
    let downloadBytes: Int64?
}

/// What is already on this Mac, so the disk rule only counts real downloads.
struct InstalledModels: Equatable, Sendable {
    var speechIDs: Set<String> = []
    var cleanupModel = false
    var translation: Set<TranslationModelID> = []
}

enum ModelAdvisor {
    /// Downloads must leave at least this much free.
    static let minimumFreeBytesAfterDownload: Int64 = 5_000_000_000

    static func fits(_ bytes: Int64?, profile: HardwareProfile) -> Bool {
        guard let bytes else { return true }
        return profile.freeDiskBytes - bytes >= minimumFreeBytesAfterDownload
    }

    /// The big translation model needs 24 GB, and never runs on a base
    /// M1, M2 or M3 even with that much memory.
    static func allowsBigTranslationModel(_ profile: HardwareProfile) -> Bool {
        guard profile.memoryGB >= 24 else { return false }
        let chip = profile.chip
        if chip.isHighTier { return true }
        if chip.tier == .base, let generation = chip.generation, generation >= 4 { return true }
        return false
    }

    /// `languages` are the dictation languages ("auto" or empty for any);
    /// see ModelAdvisor+Languages.swift.
    static func recommend(
        for profile: HardwareProfile,
        installed: InstalledModels = InstalledModels(),
        languages: Set<String> = [],
        whisperAvailable: Bool = true,
        qwen3ASRAvailable: Bool = true
    ) -> [ModelRecommendation] {
        let prefix = "\(profile.chip.shortName), \(profile.memoryGB) GB: "
        let languagePick = languageFit(profile, installed: installed, prefix: prefix, languages: languages, whisperAvailable: whisperAvailable, qwen3ASRAvailable: qwen3ASRAvailable)
        return [
            languagePick ?? speech(profile, installed: installed, prefix: prefix),
            cleanup(profile, installed: installed, prefix: prefix),
            translation(profile, installed: installed, prefix: prefix)
        ]
    }

    private static func speech(_ profile: HardwareProfile, installed: InstalledModels, prefix: String) -> ModelRecommendation {
        // Every dictation language the app offers is one of Parakeet v3's
        // 25, so Parakeet leads everywhere; the reason says when Whisper
        // Large v3 Turbo is also comfortable for other languages.
        let id = ModelCatalog.recommendedID
        let option = ModelCatalog.option(for: id)
        let bytes = installed.speechIDs.contains(id) ? nil : option?.downloadBytes
        guard fits(bytes, profile: profile) else {
            return ModelRecommendation(kind: .speech, choice: .none, title: option?.name ?? id,
                                       reason: prefix + L10n.tr("Not enough free space for this download. Keep the model you have."),
                                       downloadBytes: bytes)
        }
        let sentence: String
        let chip = profile.chip
        if profile.memoryGB <= 8 {
            sentence = L10n.tr("Parakeet is light and fast here. Skip the big Whisper models.")
        } else if chip.isHighTier || (chip.generation ?? 0) >= 4 {
            sentence = L10n.tr("Parakeet is the fastest. Large v3 Turbo also runs fast here for other languages.")
        } else {
            sentence = L10n.tr("Parakeet for speed. Large v3 Turbo also fits for other languages.")
        }
        return ModelRecommendation(kind: .speech, choice: .speech(modelID: id), title: option?.name ?? id,
                                   reason: prefix + sentence + " " + qwen3ASRSentence(profile), downloadBytes: bytes)
    }

    /// QWEN3-ASR: the size that runs comfortably on this Mac.
    static func qwen3ASRVariant(for profile: HardwareProfile) -> Qwen3ASRVariant {
        let chip = profile.chip
        let generation = chip.generation ?? 0
        let recentChip = generation >= 4 || (generation >= 3 && chip.isHighTier)
        return profile.memoryGB >= 16 && recentChip ? .large : .small
    }

    /// QWEN3-ASR: one sentence for the languages Parakeet does not cover.
    static func qwen3ASRSentence(_ profile: HardwareProfile) -> String {
        switch qwen3ASRVariant(for: profile) {
        case .large: L10n.tr("For Chinese, Japanese, Korean and many more languages, Qwen3-ASR 1.7B.")
        case .small: L10n.tr("For Chinese, Japanese, Korean and many more languages, Qwen3-ASR 0.6B.")
        }
    }

    private static func cleanup(_ profile: HardwareProfile, installed: InstalledModels, prefix: String) -> ModelRecommendation {
        let modelBytes = installed.cleanupModel ? nil : Int64(LLMCleaner.model.approximateSizeMB) * 1_000_000
        if profile.memoryGB <= 8 {
            return ModelRecommendation(kind: .cleanup, choice: .cleanup(.verbatim), title: CleanupMode.verbatim.label,
                                       reason: prefix + L10n.tr("Skip cleanup to keep memory free for your apps."),
                                       downloadBytes: nil)
        }
        guard fits(modelBytes, profile: profile) else {
            return ModelRecommendation(kind: .cleanup, choice: .cleanup(.verbatim), title: CleanupMode.verbatim.label,
                                       reason: prefix + L10n.tr("Not enough free space for the cleanup model. Keep your words as spoken."),
                                       downloadBytes: nil)
        }
        return ModelRecommendation(kind: .cleanup, choice: .cleanup(.clean), title: "\(CleanupMode.clean.label) · Qwen 2.5 1.5B",
                                   reason: prefix + L10n.tr("Cleanup stays loaded, takes a fraction of a second and fits easily in memory."),
                                   downloadBytes: modelBytes)
    }

    private static func translation(_ profile: HardwareProfile, installed: InstalledModels, prefix: String) -> ModelRecommendation {
        func bytes(_ id: TranslationModelID) -> Int64? {
            installed.translation.contains(id) ? nil : TranslationCatalog.model(id).download?.sizeBytes
        }
        func make(_ id: TranslationModelID, _ sentence: String) -> ModelRecommendation {
            ModelRecommendation(kind: .translation, choice: .translation(id), title: TranslationCatalog.model(id).name,
                                reason: prefix + sentence, downloadBytes: bytes(id))
        }

        let bigAllowed = allowsBigTranslationModel(profile)
        if bigAllowed, fits(bytes(.hyMT2Best), profile: profile) {
            return make(.hyMT2Best, L10n.tr("The 7B translation model runs well with this much memory."))
        }
        guard fits(bytes(.hyMT2Fast), profile: profile) else {
            return ModelRecommendation(kind: .translation, choice: .none, title: TranslationCatalog.model(.hyMT2Fast).name,
                                       reason: prefix + L10n.tr("Not enough free space for a translation model. Free some space first."),
                                       downloadBytes: bytes(.hyMT2Fast))
        }
        if bigAllowed {
            return make(.hyMT2Fast, L10n.tr("Not enough free space for the 7B, so the quick 1.8B."))
        }
        if profile.memoryGB < 24 {
            return make(.hyMT2Fast, L10n.tr("The 1.8B is quick here. The 7B needs 24 GB or more."))
        }
        return make(.hyMT2Fast, L10n.tr("The 1.8B is quick here. The 7B is too heavy for this chip."))
    }
}

// MARK: - Reading this Mac

enum HardwareScanner {
    static func read() -> HardwareProfile {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = version.patchVersion > 0 || version.minorVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion)"
        return HardwareProfile(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "",
            modelIdentifier: sysctlString("hw.model") ?? "",
            memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            macOSVersion: versionString,
            freeDiskBytes: freeDiskBytes(),
            onBattery: PowerSource.isOnBattery()
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Space macOS would make available for an app download, on the volume
    /// that holds the models folder.
    static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

enum PowerSource {
    /// True when the Mac runs from its battery right now.
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// One SCAN MY MAC result, as MODELS shows it.
struct HardwareScan: Equatable, Sendable {
    let profile: HardwareProfile
    let recommendations: [ModelRecommendation]
}
