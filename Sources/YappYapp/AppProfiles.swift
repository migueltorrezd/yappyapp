import AppKit
import Foundation

// PROFILES (missing feature 9): per-app overrides keyed by the bundle ID of
// the app in front when a dictation stops. A profile changes only the
// dictations that end in its app and never the saved Setup values. Every field is optional:
// nil means "follow Setup". Managed (MDM) locks always win over a profile.

/// What happens to a finished transcript for one app.
enum ProfilePasteBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case paste
    case copyOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paste: L10n.tr("PASTE")
        case .copyOnly: L10n.tr("COPY ONLY")
        }
    }
}

/// Cleanup choices a profile can store. Stored as the raw string, which is
/// the CleanupMode raw value, so a saved file never needs a migration.
enum ProfileCleanupMode: String, CaseIterable, Identifiable, Sendable {
    case verbatim
    case clean
    case email
    case list
    case notes

    var id: String { rawValue }

    /// Every cleanup mode Setup has is offered per app.
    static let offered: [ProfileCleanupMode] = allCases

    /// The cleanup mode this choice runs.
    var mode: CleanupMode {
        CleanupMode(rawValue: rawValue) ?? .clean
    }

    var label: String { mode.label }
}

struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var bundleID: String
    var appName: String
    var language: String?
    var cleanupMode: String?
    var pasteBehavior: ProfilePasteBehavior?
    var modelPath: String?
    /// NUMBERS: a NumberStyle raw value. nil (or unknown) follows Setup.
    var numberStyle: String?

    init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String,
        language: String? = nil,
        cleanupMode: String? = nil,
        pasteBehavior: ProfilePasteBehavior? = nil,
        modelPath: String? = nil,
        numberStyle: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.language = language
        self.cleanupMode = cleanupMode
        self.pasteBehavior = pasteBehavior
        self.modelPath = modelPath
        self.numberStyle = numberStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, language, cleanupMode, pasteBehavior, modelPath, numberStyle
    }

    /// Lenient: only bundleID is required. A wrong-typed or unknown value
    /// falls back to "follow Setup" instead of dropping the profile.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let bundleID = try container.decode(String.self, forKey: .bundleID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .bundleID, in: container, debugDescription: "empty bundle ID")
        }
        self.bundleID = bundleID
        id = value(UUID.self, .id) ?? UUID()
        appName = value(String.self, .appName) ?? bundleID
        language = value(String.self, .language)
        cleanupMode = value(String.self, .cleanupMode)
        pasteBehavior = value(String.self, .pasteBehavior).flatMap(ProfilePasteBehavior.init(rawValue:))
        modelPath = value(String.self, .modelPath)
        numberStyle = value(String.self, .numberStyle)
    }

    /// True when the profile changes nothing yet.
    var followsSetup: Bool {
        language == nil && cleanupMode == nil && pasteBehavior == nil && modelPath == nil && numberStyle == nil
    }
}

/// Decodes a profile list one entry at a time, so one damaged profile costs
/// only itself. Duplicate bundle IDs keep the first profile.
struct AppProfileList: Decodable {
    var profiles: [AppProfile]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [AppProfile] = []
        while !container.isAtEnd {
            if let profile = try? container.decode(AppProfile.self) {
                result.append(profile)
            } else {
                // Skip the unreadable element so the loop advances.
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        profiles = AppProfileList.deduplicated(result)
    }

    static func deduplicated(_ profiles: [AppProfile]) -> [AppProfile] {
        var seen: Set<String> = []
        return profiles.filter { seen.insert($0.bundleID.lowercased()).inserted }
    }

    private struct DiscardedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// An override the profile asked for but did not get.
enum ProfileOverrideBlock: Equatable, Sendable {
    case languageLocked
    case modelLocked
    case pasteLocked
    case numbersLocked
    case modelMissing(String)
}

/// The settings one dictation runs with.
struct ProfileResolution: Equatable {
    /// The profile that matched the stop app, if any.
    var profile: AppProfile?
    /// Setup plus the profile, ready for transcription (English-only models
    /// already force "en"). Never saved.
    var config: AppConfig
    /// The profile's paste choice, when it applies. nil follows Setup.
    var autoPasteOverride: Bool?
    /// The profile's raw cleanup mode, when it applies.
    var cleanupMode: String?
    /// Overrides that a managed lock or a missing model blocked.
    var blocked: [ProfileOverrideBlock]
    /// False when the profile changed the language or the model, so the warm
    /// Whisper server (started with the Setup values) cannot take the audio.
    var canUseWarmServer: Bool

    var badge: DictationBadge {
        DictationBadge.make(config: config, profile: profile)
    }
}

enum AppProfileResolver {
    /// The default model check: catalog models report their own install
    /// state, a custom path must exist on disk.
    static func isModelInstalled(_ modelPath: String) -> Bool {
        if let option = ModelCatalog.option(for: ModelCatalog.selectedID(for: modelPath)) {
            return option.isInstalled
        }
        return FileManager.default.fileExists(atPath: modelPath.expandingTildeInPath)
    }

    static func profile(forBundleID bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return nil }
        return profiles.first { $0.bundleID.lowercased() == bundleID }
    }

    /// nil means the mode is unknown and cleanup follows Setup.
    static func cleanupMode(for mode: String?) -> CleanupMode? {
        guard let mode, let known = ProfileCleanupMode(rawValue: mode) else { return nil }
        return known.mode
    }

    /// nil means the mode is unknown and cleanup follows Setup.
    static func cleanupEnabled(for mode: String?) -> Bool? {
        cleanupMode(for: mode)?.usesModel
    }

    /// `base` is the live config, with managed values already applied.
    static func resolve(
        base: AppConfig,
        bundleID: String?,
        lockedKeys: Set<ManagedConfigKey>,
        isModelInstalled: (String) -> Bool = AppProfileResolver.isModelInstalled
    ) -> ProfileResolution {
        let setupConfig = TranscriptionLanguage.transcriptionConfig(from: base)
        guard let profile = profile(forBundleID: bundleID, in: base.appProfiles) else {
            return ProfileResolution(
                profile: nil,
                config: setupConfig,
                autoPasteOverride: nil,
                cleanupMode: nil,
                blocked: [],
                canUseWarmServer: true
            )
        }

        var config = base
        var blocked: [ProfileOverrideBlock] = []

        if let language = profile.language,
           LanguageCatalog.options.contains(where: { $0.code == language }) {
            if lockedKeys.contains(.language) {
                blocked.append(.languageLocked)
            } else {
                config.language = language
            }
        }

        if let modelPath = profile.modelPath, modelPath != base.modelPath {
            if lockedKeys.contains(.selectedModel) {
                blocked.append(.modelLocked)
            } else if !isModelInstalled(modelPath) {
                // Never fail a dictation over a profile: Setup's model runs.
                blocked.append(.modelMissing(modelPath))
            } else {
                config.modelPath = modelPath
            }
        }

        var autoPasteOverride: Bool?
        if let behavior = profile.pasteBehavior {
            if lockedKeys.contains(.autoPaste) {
                blocked.append(.pasteLocked)
            } else {
                autoPasteOverride = behavior == .paste
                config.autoPaste = behavior == .paste
            }
        }

        var cleanupMode: String?
        if let mode = Self.cleanupMode(for: profile.cleanupMode) {
            // Sets cleanupMode and keeps llmCleanup in step, so
            // transcribeRecording's `config.cleanup` runs this mode.
            config.cleanup = mode
            cleanupMode = profile.cleanupMode
        }

        // NUMBERS: e.g. DIGITS for a terminal. A managed lock wins.
        if let stored = profile.numberStyle, let style = NumberStyle(rawValue: stored) {
            if lockedKeys.contains(.numberStyle) {
                blocked.append(.numbersLocked)
            } else {
                config.numbers = style
            }
        }

        let effective = TranscriptionLanguage.transcriptionConfig(from: config)
        return ProfileResolution(
            profile: profile,
            config: effective,
            autoPasteOverride: autoPasteOverride,
            cleanupMode: cleanupMode,
            blocked: blocked,
            canUseWarmServer: effective.language == setupConfig.language
                && effective.modelPath == setupConfig.modelPath
        )
    }
}

// MARK: - HUD badge (missing feature 12)

/// The compact "who am I listening as" label on the HUD: profile name (when
/// one applies), language and model.
struct DictationBadge: Equatable, Sendable {
    let profileName: String?
    let language: String
    let model: String

    /// Long app names are cut so the badge never crowds the waveform.
    static let maxProfileNameLength = 12

    static func make(config: AppConfig, profile: AppProfile?) -> DictationBadge {
        // Multilingual Parakeet picks the language itself and ignores the
        // setting, so the badge says AUTO rather than claim "FR".
        let code = detectsLanguageItself(config.modelPath) ? "auto" : config.language
        let language = LanguageCatalog.options.first { $0.code == code }?.brutalLabel
            ?? code.uppercased()
        return DictationBadge(
            profileName: profile.map { shortName($0.appName) },
            language: language,
            model: modelLabel(for: config.modelPath)
        )
    }

    static func detectsLanguageItself(_ modelPath: String) -> Bool {
        guard ModelCatalog.engine(for: modelPath) == .parakeet else { return false }
        let variant = ModelCatalog.option(for: ModelCatalog.selectedID(for: modelPath))?.parakeetVariant
        return variant == "v3" || variant == "ultra"
    }

    static func shortName(_ name: String) -> String {
        let upper = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count > maxProfileNameLength else { return upper }
        return String(upper.prefix(maxProfileNameLength - 1)) + "…"
    }

    /// Short model names: "PARAKEET V3", "LARGE V3 TURBO", "SMALL EN".
    static func modelLabel(for modelPath: String) -> String {
        let name = ModelCatalog.displayName(for: modelPath)
        return name
            .replacingOccurrences(of: "Parakeet TDT", with: "Parakeet")
            .replacingOccurrences(of: "English", with: "EN")
            .replacingOccurrences(of: ".bin", with: "")
            .uppercased()
    }

    var text: String {
        ([profileName].compactMap { $0 } + [language, model]).joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var parts: [String] = []
        if let profileName { parts.append(L10n.tr("Profile %@", profileName.lowercased())) }
        parts.append(L10n.tr("language %@", language.lowercased()))
        parts.append(L10n.tr("model %@", model.lowercased()))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Apps to add

/// An app the user can make a profile for.
struct ProfileAppCandidate: Equatable, Identifiable, Sendable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

/// The apps dictations started in during this run, newest first. In memory
/// only, never written to disk.
@MainActor
final class RecentProfileApps {
    static let shared = RecentProfileApps()
    static let limit = 6

    private(set) var apps: [ProfileAppCandidate] = []

    func note(bundleID: String?, name: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        let candidate = ProfileAppCandidate(bundleID: bundleID, name: name ?? bundleID)
        apps.removeAll { $0.bundleID == bundleID }
        apps.insert(candidate, at: 0)
        if apps.count > Self.limit {
            apps.removeLast(apps.count - Self.limit)
        }
    }
}

enum ProfileAppCandidates {
    /// Recent dictation targets first, then the other running apps by name.
    /// Apps that already have a profile and YappYapp itself are left out.
    static func merge(
        recent: [ProfileAppCandidate],
        running: [ProfileAppCandidate],
        existing: [AppProfile],
        ownBundleID: String?
    ) -> [ProfileAppCandidate] {
        var taken = Set(existing.map { $0.bundleID.lowercased() })
        if let ownBundleID { taken.insert(ownBundleID.lowercased()) }
        var result: [ProfileAppCandidate] = []
        for candidate in recent + running.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        where taken.insert(candidate.bundleID.lowercased()).inserted {
            result.append(candidate)
        }
        return result
    }

    /// Live list for the Settings picker. Reads only the running-app list.
    @MainActor
    static func current(existing: [AppProfile]) -> [ProfileAppCandidate] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> ProfileAppCandidate? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return ProfileAppCandidate(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
        return merge(
            recent: RecentProfileApps.shared.apps,
            running: running,
            existing: existing,
            ownBundleID: Bundle.main.bundleIdentifier
        )
    }
}
