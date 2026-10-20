import Foundation

// MANAGED-PREFS: an IT admin can force a handful of settings through a
// configuration profile (MDM) for the app's bundle ID. Forced values override
// config.json, show as LOCKED in Settings, and are never written back over the
// user's own saved value, so removing the profile restores the user's choice.
// docs/MANAGED_INSTALLS.md lists the keys and carries a sample profile.

/// The settings an admin can force. Raw values are the profile payload keys.
enum ManagedConfigKey: String, CaseIterable, Sendable {
    case allowModelDownloads
    case automaticUpdateChecks
    case selectedModel
    case language
    case petEnabled
    case autoPaste
    case learnFromFixes
    case numberStyle
}

/// A forced value as read from the managed domain, already de-CF'd.
enum ManagedValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Injectable so tests never touch the real preferences system.
protocol ManagedPreferencesReading: Sendable {
    func forcedValue(forKey key: String) -> ManagedValue?
}

/// Reads forced (managed) values for the running app bundle. It reads nothing
/// in an unbundled process (CLI diagnostics, --self-test, swift test), so tests
/// and smoke runs never see the host Mac's profiles.
struct SystemManagedPreferences: ManagedPreferencesReading {
    let applicationID: String?

    static var current: SystemManagedPreferences {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let identifier = bundle.bundleIdentifier,
              !identifier.isEmpty else {
            return SystemManagedPreferences(applicationID: nil)
        }
        return SystemManagedPreferences(applicationID: identifier)
    }

    func forcedValue(forKey key: String) -> ManagedValue? {
        guard let applicationID else { return nil }
        let appID = applicationID as CFString
        guard CFPreferencesAppValueIsForced(key as CFString, appID),
              let raw = CFPreferencesCopyAppValue(key as CFString, appID) else {
            return nil
        }
        return Self.managedValue(from: raw)
    }

    static func managedValue(from raw: CFPropertyList) -> ManagedValue? {
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue((raw as! CFBoolean)))
        }
        if let number = raw as? NSNumber {
            return .number(number.doubleValue)
        }
        if let string = raw as? String {
            return .string(string)
        }
        return nil
    }
}

/// Fixed values for tests and previews.
struct StaticManagedPreferences: ManagedPreferencesReading {
    let values: [String: ManagedValue]

    init(_ values: [ManagedConfigKey: ManagedValue] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    func forcedValue(forKey key: String) -> ManagedValue? {
        values[key]
    }
}

/// The validated forced settings. A key with a value the app cannot use
/// (a typo'd language, an unknown model) is ignored and stays unlocked.
struct ManagedOverrides: Equatable, Sendable {
    var allowModelDownloads: Bool?
    var automaticUpdateChecks: Bool?
    var modelPath: String?
    var language: String?
    var petEnabled: Bool?
    var autoPaste: Bool?
    var learnFromFixes: Bool?
    var numberStyle: NumberStyle?

    static let none = ManagedOverrides()

    static func read(from reader: ManagedPreferencesReading) -> ManagedOverrides {
        var overrides = ManagedOverrides()
        overrides.allowModelDownloads = reader.forcedValue(forKey: ManagedConfigKey.allowModelDownloads.rawValue)?.boolValue
        overrides.automaticUpdateChecks = reader.forcedValue(forKey: ManagedConfigKey.automaticUpdateChecks.rawValue)?.boolValue
        overrides.modelPath = reader.forcedValue(forKey: ManagedConfigKey.selectedModel.rawValue)?.stringValue
            .flatMap(modelPath(forManagedSelection:))
        overrides.language = reader.forcedValue(forKey: ManagedConfigKey.language.rawValue)?.stringValue
            .flatMap { value in
                LanguageCatalog.options.first { $0.code == value.lowercased() }?.code
            }
        overrides.petEnabled = reader.forcedValue(forKey: ManagedConfigKey.petEnabled.rawValue)?.boolValue
        overrides.autoPaste = reader.forcedValue(forKey: ManagedConfigKey.autoPaste.rawValue)?.boolValue
        overrides.learnFromFixes = reader.forcedValue(forKey: ManagedConfigKey.learnFromFixes.rawValue)?.boolValue
        // NUMBERS: "spoken", "digits" or "words"; anything else stays unlocked.
        overrides.numberStyle = reader.forcedValue(forKey: ManagedConfigKey.numberStyle.rawValue)?.stringValue
            .flatMap { NumberStyle(rawValue: $0.lowercased()) }
        return overrides
    }

    /// A catalog ID ("parakeet-v3", "large-v3-turbo") or a model location the
    /// app already understands: a parakeet:// URL or an absolute file path.
    static func modelPath(forManagedSelection selection: String) -> String? {
        if let option = ModelCatalog.option(for: selection) {
            return option.defaultPath
        }
        if selection.hasPrefix("parakeet://") || selection.hasPrefix(Qwen3ASRVariant.scheme),
           ModelCatalog.options.contains(where: { $0.defaultPath == selection }) {
            return selection
        }
        let expanded = selection.expandingTildeInPath
        if expanded.hasPrefix("/"), !expanded.contains("/../") {
            return selection
        }
        return nil
    }

    /// Keys that the profile actually forces. petEnabled only locks the pet
    /// when it turns the pet off; forcing it on leaves the choice to the user.
    var lockedKeys: Set<ManagedConfigKey> {
        var keys: Set<ManagedConfigKey> = []
        if allowModelDownloads != nil { keys.insert(.allowModelDownloads) }
        if automaticUpdateChecks != nil { keys.insert(.automaticUpdateChecks) }
        if modelPath != nil { keys.insert(.selectedModel) }
        if language != nil { keys.insert(.language) }
        if petEnabled == false { keys.insert(.petEnabled) }
        if autoPaste != nil { keys.insert(.autoPaste) }
        if learnFromFixes != nil { keys.insert(.learnFromFixes) }
        if numberStyle != nil { keys.insert(.numberStyle) }
        return keys
    }

    func apply(to config: AppConfig) -> AppConfig {
        var result = config
        if let allowModelDownloads { result.allowModelDownloads = allowModelDownloads }
        if let automaticUpdateChecks { result.automaticUpdateChecks = automaticUpdateChecks }
        if let modelPath { result.modelPath = modelPath }
        if let language { result.language = language }
        if petEnabled == false {
            result.petEnabled = false
            result.pet = PetKind.none.rawValue
        }
        // autoPaste is the YA-17 master switch ("AUTO-PASTE AT THE CURSOR").
        if let autoPaste { result.autoPaste = autoPaste }
        if let learnFromFixes { result.learnFromFixes = learnFromFixes }
        if let numberStyle { result.numbers = numberStyle }
        return result
    }

    /// Before saving, put the user's own value back into every locked field so
    /// the forced value never overwrites what the user chose.
    func restoringUserValues(in config: AppConfig, from persisted: AppConfig) -> AppConfig {
        var result = config
        let locked = lockedKeys
        if locked.contains(.allowModelDownloads) { result.allowModelDownloads = persisted.allowModelDownloads }
        if locked.contains(.automaticUpdateChecks) { result.automaticUpdateChecks = persisted.automaticUpdateChecks }
        if locked.contains(.selectedModel) { result.modelPath = persisted.modelPath }
        if locked.contains(.language) { result.language = persisted.language }
        if locked.contains(.petEnabled) {
            result.petEnabled = persisted.petEnabled
            result.pet = persisted.pet
        }
        if locked.contains(.autoPaste) { result.autoPaste = persisted.autoPaste }
        if locked.contains(.learnFromFixes) { result.learnFromFixes = persisted.learnFromFixes }
        if locked.contains(.numberStyle) { result.numberStyle = persisted.numberStyle }
        return result
    }
}

enum ManagedPreferencesCopy {
    static var lockedTag: String { L10n.tr("LOCKED") }
    static var lockedHelp: String { L10n.tr("Set by your organization. Ask your IT admin to change it.") }
    static var modelLockedStatus: String { L10n.tr("Your organization picks the model on this Mac.") }
    static var petLockedTitle: String { L10n.tr("PET TURNED OFF") }
}
