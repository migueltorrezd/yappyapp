import Foundation

// CONFIG-RECOVERY (YA-26): config.json is decoded key by key. One bad value
// costs only that value, never the whole file. A damaged file (unreadable
// JSON, a wrong-typed value, or a missing core key) is repaired from the
// last saved copy when one exists, and otherwise:
// - model downloads fail closed (off) instead of silently turning back on,
// - every other unrecoverable key falls back to its install default,
// - the damaged bytes are kept next to config.json for diagnosis,
// - the user sees one notice that says what happened.

/// The one-time notice shown after a damaged settings file was repaired.
struct ConfigRecoveryNotice: Equatable, Sendable {
    let backupFileName: String?
    let restoredFromLastSave: Bool
    let downloadsTurnedOff: Bool

    var title: String { L10n.tr("SETTINGS FILE REPAIRED") }

    var message: String {
        var parts = [restoredFromLastSave
            ? L10n.tr("Your settings file was damaged. Your last saved settings are back.")
            : L10n.tr("Your settings file was damaged. Anything unreadable went back to its default.")]
        if downloadsTurnedOff {
            parts.append(L10n.tr("Model downloads stay off until you turn them on in Setup."))
        }
        if let backupFileName {
            parts.append(L10n.tr("The damaged copy is saved as %@.", backupFileName))
        }
        return parts.joined(separator: " ")
    }
}

struct ConfigDecodeOutcome: Equatable {
    var config: AppConfig
    /// The file needs repair: unreadable, wrong-typed, or missing core keys.
    var isDamaged: Bool
    /// The bytes were not a JSON object at all (values were salvaged by scan).
    var wasUnreadable: Bool
    var invalidKeys: [String]
    var missingCoreKeys: [String]
    var restoredFromLastSave: Bool
    /// Downloads were forced off because no trustworthy value survived.
    var downloadsFailedClosed: Bool
}

enum ConfigRecovery {
    enum FieldType {
        case string
        case optionalString
        case bool
        case number
        /// A nested JSON object, decoded by its own type (SHORTCUTS).
        case object
        /// A JSON array, decoded by its own type (PROFILES).
        case array
    }

    static let fieldTypes: [String: FieldType] = [
        "whisperBinaryPath": .string,
        "modelPath": .string,
        "language": .string,
        "additionalPrompt": .string,
        "maxRecordingSeconds": .number,
        // Checked for type only; the value is ignored (always restored).
        "restoreClipboardAfterPaste": .bool,
        "pasteWhenFocusIsUnclear": .bool,
        "keepModelWarm": .bool,
        "superFastMode": .bool,
        "llmCleanup": .bool,
        "llamaBinaryPath": .string,
        "automaticUpdateChecks": .bool,
        "inputDeviceUID": .optionalString,
        "hudPosition": .string,
        "playSounds": .bool,
        "removeFillerWords": .bool,
        "translateToEnglish": .bool,
        "translateTarget": .string,
        "translationModel": .string,
        "quietVoiceBoost": .bool,
        "pet": .string,
        "accessory": .string,
        "allowModelDownloads": .bool,
        "hasCompletedGuidedSetup": .bool,
        "petEnabled": .bool,
        "textSize": .string,
        "autoPaste": .bool,
        "escCancelsRecording": .bool,
        "showTextInNotifications": .bool,
        "shortcuts": .object,
        "cleanupMode": .string,
        "spokenCommands": .bool,
        "appProfiles": .array,
        "livePreview": .bool,
        "appLanguage": .string,
        "learnFromFixes": .bool,
        "numberStyle": .string
    ]

    /// Keys every config.json has carried since the first release. A file
    /// without them was cut short, not written by an older version.
    /// restoreClipboardAfterPaste is still written (always true) but its value
    /// is ignored: the clipboard always comes back after a paste.
    static let coreKeys = [
        "whisperBinaryPath",
        "modelPath",
        "language",
        "additionalPrompt",
        "maxRecordingSeconds",
        "restoreClipboardAfterPaste",
        "pasteWhenFocusIsUnclear"
    ]

    static func decode(
        data: Data,
        installDefaults: AppConfig,
        lastSaved: () -> AppConfig?,
        hasPriorUse: () -> Bool = { false }
    ) -> ConfigDecodeOutcome {
        var wasUnreadable = false
        let fields: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields = object
        } else {
            wasUnreadable = true
            fields = salvageScalars(from: data)
        }

        // Unknown keys (like the removed "appearance") are ignored, not damage.
        let invalidKeys = fields.keys
            .filter { key in fieldTypes[key].map { !isValid(fields[key], as: $0) } ?? false }
            .sorted()
        let missingCoreKeys = coreKeys.filter { fields[$0] == nil }
        let isDamaged = wasUnreadable || !invalidKeys.isEmpty || !missingCoreKeys.isEmpty

        let saved = isDamaged ? lastSaved() : nil
        var config = saved ?? installDefaults
        let valid = fields.filter { key, value in
            fieldTypes[key].map { isValid(value, as: $0) } ?? false
        }

        if let value = valid["whisperBinaryPath"] as? String { config.whisperBinaryPath = value }
        if let value = valid["modelPath"] as? String { config.modelPath = value }
        if let value = valid["language"] as? String { config.language = value }
        if let value = valid["additionalPrompt"] as? String { config.additionalPrompt = value }
        if let value = valid["maxRecordingSeconds"] as? NSNumber { config.maxRecordingSeconds = value.doubleValue }
        if let value = bool(valid["pasteWhenFocusIsUnclear"]) { config.pasteWhenFocusIsUnclear = value }
        if let value = bool(valid["keepModelWarm"]) { config.keepModelWarm = value }
        if let value = bool(valid["superFastMode"]) { config.superFastMode = value }
        if let value = bool(valid["llmCleanup"]) { config.llmCleanup = value }
        if let value = valid["llamaBinaryPath"] as? String { config.llamaBinaryPath = value }
        // LLM-CLEANUP: a file without modes follows its on/off switch.
        if let value = valid["cleanupMode"] as? String {
            config.cleanup = CleanupMode.resolve(stored: value, legacyEnabled: config.llmCleanup)
        } else if let value = bool(valid["llmCleanup"]) {
            config.cleanup = value ? (config.cleanup.usesModel ? config.cleanup : .clean) : .verbatim
        }
        if let value = bool(valid["automaticUpdateChecks"]) { config.automaticUpdateChecks = value }
        if let value = valid["inputDeviceUID"] {
            config.inputDeviceUID = value as? String
        }
        if let value = valid["hudPosition"] as? String { config.hudPosition = HUDPosition.normalized(value) }
        if let value = bool(valid["playSounds"]) { config.playSounds = value }
        if let value = bool(valid["removeFillerWords"]) { config.removeFillerWords = value }
        // TRANSLATION: a file without targets migrates from its old switch.
        let migratedTranslation = AppConfig.migratedTranslation(
            storedTarget: valid["translateTarget"] as? String,
            storedModel: valid["translationModel"] as? String,
            legacyTranslateToEnglish: bool(valid["translateToEnglish"]) ?? false,
            modelPath: config.modelPath
        )
        if valid["translateTarget"] != nil || bool(valid["translateToEnglish"]) != nil {
            config.translateTarget = migratedTranslation.target
        }
        if valid["translationModel"] != nil || bool(valid["translateToEnglish"]) != nil {
            config.translationModel = migratedTranslation.model
        }
        if let value = bool(valid["quietVoiceBoost"]) { config.quietVoiceBoost = value }
        if let value = valid["pet"] as? String { config.pet = value }
        if let value = valid["accessory"] as? String { config.accessory = value }
        if let value = bool(valid["petEnabled"]) { config.petEnabled = value }
        if let value = valid["textSize"] as? String { config.textSize = value }
        if let value = bool(valid["autoPaste"]) {
            config.autoPaste = value
        } else if fields["autoPaste"] == nil, let legacy = bool(valid["pasteWhenFocusIsUnclear"]) {
            // YA-17: a file from before the master switch keeps what the old
            // "TYPE INTO THE ACTIVE APP" toggle said.
            config.autoPaste = legacy
        }
        if let value = bool(valid["escCancelsRecording"]) { config.escCancelsRecording = value }
        if let value = bool(valid["showTextInNotifications"]) { config.showTextInNotifications = value }
        if let value = bool(valid["spokenCommands"]) { config.spokenCommands = value }
        if let value = bool(valid["livePreview"]) { config.livePreview = value }
        if let value = valid["appLanguage"] as? String { config.appLanguage = value }
        if let value = bool(valid["learnFromFixes"]) { config.learnFromFixes = value }
        if let value = valid["numberStyle"] as? String { config.numbers = NumberStyle.resolve(value) }
        if let object = valid["shortcuts"],
           let data = try? JSONSerialization.data(withJSONObject: object),
           let value = try? JSONDecoder().decode(ShortcutSettings.self, from: data) {
            config.shortcuts = value
        }
        if let array = valid["appProfiles"],
           let data = try? JSONSerialization.data(withJSONObject: array),
           let value = try? JSONDecoder().decode(AppProfileList.self, from: data) {
            config.appProfiles = value.profiles
        }
        if let value = bool(valid["hasCompletedGuidedSetup"]) {
            config.hasCompletedGuidedSetup = value
        } else if isDamaged, saved == nil, hasPriorUse() {
            // The flag was lost with the damage, but this Mac has dictated
            // before. Setup finished, so the wizard must not come back.
            config.hasCompletedGuidedSetup = true
        }

        var downloadsFailedClosed = false
        if let value = bool(valid["allowModelDownloads"]) {
            config.allowModelDownloads = value
        } else if isDamaged {
            // Fail closed: a managed offline install must never come back
            // online because its config file got cut short.
            if let saved {
                config.allowModelDownloads = saved.allowModelDownloads
            } else {
                config.allowModelDownloads = false
                downloadsFailedClosed = true
            }
        } else {
            // An intact file from before the key existed: keep the old default.
            config.allowModelDownloads = true
        }

        return ConfigDecodeOutcome(
            config: config,
            isDamaged: isDamaged,
            wasUnreadable: wasUnreadable,
            invalidKeys: invalidKeys,
            missingCoreKeys: missingCoreKeys,
            restoredFromLastSave: saved != nil,
            downloadsFailedClosed: downloadsFailedClosed
        )
    }

    /// A stats.json that counts at least one finished dictation means setup
    /// was done on this Mac at some point.
    static func hasPriorUse(in supportDirectory: URL) -> Bool {
        let url = supportDirectory.appendingPathComponent("stats.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dictations = object["totalDictations"] as? NSNumber else {
            return false
        }
        return dictations.intValue > 0
    }

    static func isValid(_ value: Any?, as type: FieldType) -> Bool {
        guard let value else { return false }
        switch type {
        case .string:
            return value is String
        case .optionalString:
            return value is String || value is NSNull
        case .bool:
            return bool(value) != nil
        case .number:
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return number.doubleValue.isFinite
        case .object:
            return value is [String: Any]
        case .array:
            return value is [Any]
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Best-effort scan of a truncated or mangled file for `"key": scalar`
    /// pairs. Only known keys survive, and only as JSON scalars.
    static func salvageScalars(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let pattern = #""([A-Za-z][A-Za-z0-9]*)"\s*:\s*(true|false|null|-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?|"(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }

        var result: [String: Any] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyRange])
            guard fieldTypes[key] != nil, result[key] == nil else { continue }
            let literal = Data(text[valueRange].utf8)
            if let value = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) {
                result[key] = value
            }
        }
        return result
    }
}
