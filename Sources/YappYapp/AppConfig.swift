import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    var whisperBinaryPath: String
    var modelPath: String
    var language: String
    var additionalPrompt: String
    var maxRecordingSeconds: Double
    // CLIPBOARD (0.4.0): the clipboard always comes back after a paste. The
    // old SETUP switch is gone. The key is still written (always true) so an
    // older build reading this file finds it, and any stored value is ignored.
    private(set) var restoreClipboardAfterPaste = true
    var pasteWhenFocusIsUnclear: Bool
    var keepModelWarm: Bool
    // SUPER-FAST-MODE: keep the microphone capture session warm with a short
    // in-memory ring buffer so the first word is never clipped. Off by default
    // on purpose: a warm mic keeps the macOS microphone indicator (orange dot)
    // lit the entire time the app runs, which contradicts the privacy-first
    // default posture. The settings toggle carries that warning.
    var superFastMode: Bool
    // LLM-CLEANUP: opt-in tidy pass through a small local model after
    // transcription (punctuation, capitalization, false starts). Off by
    // default: it adds ~1-2s per dictation and ~1.3 GB of RAM while cleaning,
    // and an LLM stage rewrites what was said — power users opt in knowingly.
    var llmCleanup: Bool
    var llamaBinaryPath: String
    // UPDATES: Sparkle auto-check (packaged builds only). On by default with a
    // visible off switch; the check sends version numbers to the release feed
    // and nothing else — the one network call besides model downloads.
    var automaticUpdateChecks: Bool
    var inputDeviceUID: String?
    var hudPosition: String
    var playSounds: Bool
    var removeFillerWords: Bool
    // TRANSLATION (round 2): legacy mirror of the old TRANSLATE TO ENGLISH
    // switch, still written so an older build reading this file keeps
    // Whisper's -tr when it was on. True only on the Whisper built-in route
    // to English. Read and write translation through `translation` and
    // `translationModelID`.
    private(set) var translateToEnglish: Bool
    // TRANSLATION: target language raw value ("off", "en", "fr", ...) and the
    // chosen translation model ("hy-mt2-1.8b", "hy-mt2-7b", "whisper").
    // Absent in older configs, which migrate from translateToEnglish.
    var translateTarget: String {
        didSet { syncLegacyTranslateFlag() }
    }
    var translationModel: String {
        didSet { syncLegacyTranslateFlag() }
    }
    var quietVoiceBoost: Bool
    var pet: String
    var accessory: String
    var allowModelDownloads: Bool
    // GUIDED-FIRST-RUN: false until the user finishes the ordered onboarding
    // wizard once; afterward the home card reverts to listing only the
    // outstanding issues instead of one numbered step at a time.
    var hasCompletedGuidedSetup: Bool
    // YA-31: the "Pet and quests" master switch. Off silences quests, pet
    // messages, jingles, confetti, the walking pet and the recap prompt.
    var petEnabled: Bool
    // TEXT-SIZE: in-app type scale (small, default, large, larger). Stored as
    // the raw string; unknown values render at the default size.
    var textSize: String
    // PIPELINE (YA-17): master switch for typing into the active app. Off means
    // every dictation is copied only, never pasted.
    var autoPaste: Bool
    // PIPELINE (YA-19): Esc cancels a running dictation (global while recording).
    var escCancelsRecording: Bool
    // PIPELINE: delivery notifications never carry the transcript unless the
    // user opts in. Off by default.
    var showTextInNotifications: Bool
    // SHORTCUTS: global shortcuts and recording mode. Absent in older configs,
    // which keep Option+Space in toggle mode.
    var shortcuts: ShortcutSettings
    // LLM-CLEANUP: cleanup mode raw value (verbatim, clean, email, list,
    // notes). Absent in older configs, which follow llmCleanup. Read it
    // through `cleanup`.
    var cleanupMode: String
    // COMMANDS: spoken edit commands ("new line", "scratch that"). On by
    // default; absent in older configs, which turn it on.
    var spokenCommands: Bool
    // PROFILES: per-app overrides keyed by bundle ID. Absent in older configs,
    // which have none.
    var appProfiles: [AppProfile]
    // LIVE-PREVIEW: show the words heard so far in the HUD while recording.
    // Parakeet only, never pasted. Off by default and absent in older configs.
    var livePreview: Bool
    // L10N (YA-42): interface language ("system", "en", "fr", "es", "nl").
    // Absent in older configs, which follow the system language.
    var appLanguage: String
    // LEARN-FROM-FIXES: after a paste, read back only the pasted text for a
    // few seconds and learn a name the user corrects by hand. On by default;
    // absent in older configs, which turn it on.
    var learnFromFixes: Bool
    // NUMBERS: how numbers are written ("spoken", "digits", "words"). Absent
    // in older configs, which keep numbers as spoken. Read it through `numbers`.
    var numberStyle: String

    init(
        whisperBinaryPath: String,
        modelPath: String,
        language: String,
        additionalPrompt: String,
        maxRecordingSeconds: Double,
        pasteWhenFocusIsUnclear: Bool,
        keepModelWarm: Bool = true,
        superFastMode: Bool = false,
        llmCleanup: Bool = false,
        llamaBinaryPath: String = "/opt/homebrew/bin/llama-cli",
        automaticUpdateChecks: Bool = true,
        inputDeviceUID: String? = nil,
        hudPosition: String = "bottom",
        playSounds: Bool = true,
        removeFillerWords: Bool = false,
        translateTarget: String = "off",
        translationModel: String = TranslationCatalog.defaultModelID.rawValue,
        quietVoiceBoost: Bool = true,
        pet: String = "cat",
        accessory: String = "none",
        allowModelDownloads: Bool = true,
        hasCompletedGuidedSetup: Bool = false,
        petEnabled: Bool = true,
        textSize: String = "default",
        autoPaste: Bool = true,
        escCancelsRecording: Bool = true,
        showTextInNotifications: Bool = false,
        shortcuts: ShortcutSettings = .default,
        cleanupMode: String? = nil,
        spokenCommands: Bool = true,
        appProfiles: [AppProfile] = [],
        livePreview: Bool = false,
        appLanguage: String = "system",
        learnFromFixes: Bool = true,
        numberStyle: String = NumberStyle.asSpoken.rawValue
    ) {
        self.whisperBinaryPath = whisperBinaryPath
        self.modelPath = modelPath
        self.language = language
        self.additionalPrompt = additionalPrompt
        self.maxRecordingSeconds = maxRecordingSeconds
        self.pasteWhenFocusIsUnclear = pasteWhenFocusIsUnclear
        self.keepModelWarm = keepModelWarm
        self.superFastMode = superFastMode
        self.llmCleanup = llmCleanup
        self.llamaBinaryPath = llamaBinaryPath
        self.automaticUpdateChecks = automaticUpdateChecks
        self.inputDeviceUID = inputDeviceUID
        self.hudPosition = hudPosition
        self.playSounds = playSounds
        self.removeFillerWords = removeFillerWords
        self.translateTarget = translateTarget
        self.translationModel = translationModel
        self.translateToEnglish = AppConfig.legacyTranslateFlag(target: translateTarget, model: translationModel)
        self.quietVoiceBoost = quietVoiceBoost
        self.pet = pet
        self.accessory = accessory
        self.allowModelDownloads = allowModelDownloads
        self.hasCompletedGuidedSetup = hasCompletedGuidedSetup
        self.petEnabled = petEnabled
        self.textSize = textSize
        self.autoPaste = autoPaste
        self.escCancelsRecording = escCancelsRecording
        self.showTextInNotifications = showTextInNotifications
        self.shortcuts = shortcuts
        self.cleanupMode = cleanupMode ?? (llmCleanup ? CleanupMode.clean : CleanupMode.verbatim).rawValue
        self.spokenCommands = spokenCommands
        self.appProfiles = appProfiles
        self.livePreview = livePreview
        self.appLanguage = appLanguage
        self.learnFromFixes = learnFromFixes
        self.numberStyle = numberStyle
    }

    // Older config.json files lack the newer keys, so they decode with defaults.
    // CONFIG-RECOVERY (YA-26): every key decodes on its own, so one wrong-typed
    // or missing value costs only that value. allowModelDownloads fails closed:
    // a value that is present but unreadable means off, never on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig.defaultConfig
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        whisperBinaryPath = value(String.self, .whisperBinaryPath) ?? defaults.whisperBinaryPath
        modelPath = value(String.self, .modelPath) ?? defaults.modelPath
        language = value(String.self, .language) ?? defaults.language
        additionalPrompt = value(String.self, .additionalPrompt) ?? defaults.additionalPrompt
        maxRecordingSeconds = value(Double.self, .maxRecordingSeconds) ?? defaults.maxRecordingSeconds
        pasteWhenFocusIsUnclear = value(Bool.self, .pasteWhenFocusIsUnclear) ?? defaults.pasteWhenFocusIsUnclear
        keepModelWarm = value(Bool.self, .keepModelWarm) ?? true
        // SUPER-FAST-MODE: absent in older configs and deliberately opt-in.
        superFastMode = value(Bool.self, .superFastMode) ?? false
        // LLM-CLEANUP: absent in older configs and deliberately opt-in.
        llmCleanup = value(Bool.self, .llmCleanup) ?? false
        llamaBinaryPath = value(String.self, .llamaBinaryPath) ?? "/opt/homebrew/bin/llama-cli"
        automaticUpdateChecks = value(Bool.self, .automaticUpdateChecks) ?? true
        inputDeviceUID = value(String.self, .inputDeviceUID)
        hudPosition = HUDPosition.normalized(value(String.self, .hudPosition) ?? "bottom")
        playSounds = value(Bool.self, .playSounds) ?? true
        removeFillerWords = value(Bool.self, .removeFillerWords) ?? false
        // TRANSLATION: older configs carry only translateToEnglish.
        let migrated = AppConfig.migratedTranslation(
            storedTarget: value(String.self, .translateTarget),
            storedModel: value(String.self, .translationModel),
            legacyTranslateToEnglish: value(Bool.self, .translateToEnglish) ?? false,
            modelPath: modelPath
        )
        translateTarget = migrated.target
        translationModel = migrated.model
        translateToEnglish = AppConfig.legacyTranslateFlag(target: migrated.target, model: migrated.model)
        quietVoiceBoost = value(Bool.self, .quietVoiceBoost) ?? true
        pet = value(String.self, .pet) ?? "cat"
        accessory = value(String.self, .accessory) ?? "none"
        if container.contains(.allowModelDownloads) {
            allowModelDownloads = value(Bool.self, .allowModelDownloads) ?? false
        } else {
            allowModelDownloads = true
        }
        // GUIDED-FIRST-RUN: legacy config.json predates this key, so an absent
        // value means the wizard has never run; default false so it shows once.
        hasCompletedGuidedSetup = value(Bool.self, .hasCompletedGuidedSetup) ?? false
        // YA-31: older configs predate the switch; the pet stays on.
        petEnabled = value(Bool.self, .petEnabled) ?? true
        // TEXT-SIZE: absent in older configs, which render at the default size.
        textSize = value(String.self, .textSize) ?? "default"
        // PIPELINE (YA-17): absent in older configs. The old "TYPE INTO THE
        // ACTIVE APP" toggle was this flag's stand-in, so honor what it said.
        autoPaste = value(Bool.self, .autoPaste) ?? pasteWhenFocusIsUnclear
        escCancelsRecording = value(Bool.self, .escCancelsRecording) ?? true
        showTextInNotifications = value(Bool.self, .showTextInNotifications) ?? false
        // SHORTCUTS: a damaged shortcuts block falls back to the defaults
        // instead of failing the whole config.
        shortcuts = value(ShortcutSettings.self, .shortcuts) ?? .default
        // LLM-CLEANUP: older configs carry only the on/off switch.
        cleanupMode = CleanupMode.resolve(
            stored: value(String.self, .cleanupMode),
            legacyEnabled: llmCleanup
        ).rawValue
        spokenCommands = value(Bool.self, .spokenCommands) ?? true
        // PROFILES: one damaged profile costs only itself.
        appProfiles = value(AppProfileList.self, .appProfiles)?.profiles ?? []
        // LIVE-PREVIEW: absent in older configs and deliberately opt-in.
        livePreview = value(Bool.self, .livePreview) ?? false
        // L10N: absent in older configs, which follow the system language.
        appLanguage = value(String.self, .appLanguage) ?? "system"
        // LEARN-FROM-FIXES: absent in older configs, on by default.
        learnFromFixes = value(Bool.self, .learnFromFixes) ?? true
        // NUMBERS: absent in older configs; an unknown value means as spoken.
        numberStyle = NumberStyle.resolve(value(String.self, .numberStyle)).rawValue
    }

    static func legacyTranslateFlag(target: String, model: String) -> Bool {
        target == TranslationTarget.en.rawValue && model == TranslationModelID.whisperBuiltIn.rawValue
    }

    private mutating func syncLegacyTranslateFlag() {
        translateToEnglish = AppConfig.legacyTranslateFlag(target: translateTarget, model: translationModel)
    }

    static let defaultConfig = AppConfig(
        whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
        modelPath: "parakeet://ultra",  // PARAKEET-FIRST: default engine
        language: "auto",
        additionalPrompt: "Company vocabulary and exact spellings may include product names, client names, internal tools, acronyms, and multilingual business terminology.",
        maxRecordingSeconds: 300,
        pasteWhenFocusIsUnclear: true
    )
}

enum AppPaths {
    static let supportDirectoryToken = "~/Library/Application Support/YappYapp"
    static let legacySupportDirectoryToken = "~/Library/Application Support/YappYappLegacy"
    static let applicationSupportBaseEnvironmentKey = "YAPPYAPP_APP_SUPPORT_BASE"
    private static let applicationSupportBaseOverrideLock = NSLock()
    nonisolated(unsafe) private static var storedApplicationSupportBaseOverride: URL?

    /// Test and smoke harness override. Access is synchronized because strict
    /// concurrency treats mutable global configuration as shared state.
    static var applicationSupportBaseOverride: URL? {
        get {
            applicationSupportBaseOverrideLock.lock()
            defer { applicationSupportBaseOverrideLock.unlock() }
            return storedApplicationSupportBaseOverride
        }
        set {
            applicationSupportBaseOverrideLock.lock()
            storedApplicationSupportBaseOverride = newValue
            applicationSupportBaseOverrideLock.unlock()
        }
    }

    static var customApplicationSupportBaseFromEnvironment: URL? {
        guard let environmentPath = ProcessInfo.processInfo.environment[applicationSupportBaseEnvironmentKey],
              !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: environmentPath.expandingTildeInPath)
    }

    static var usesCustomApplicationSupportBase: Bool {
        applicationSupportBaseOverride != nil || customApplicationSupportBaseFromEnvironment != nil
    }

    static var applicationSupportBase: URL {
        if let applicationSupportBaseOverride {
            return applicationSupportBaseOverride
        }

        if let customApplicationSupportBaseFromEnvironment {
            return customApplicationSupportBaseFromEnvironment
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var supportDirectory: URL {
        applicationSupportBase.appendingPathComponent("YappYapp", isDirectory: true)
    }

    static var legacySupportDirectory: URL {
        applicationSupportBase.appendingPathComponent("YappYappLegacy", isDirectory: true)
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static var glossaryURL: URL {
        supportDirectory.appendingPathComponent("glossary.json")
    }

    /// LEARN-FROM-FIXES: words never to learn again (folded keys only).
    static var neverLearnURL: URL {
        supportDirectory.appendingPathComponent("learn-never.json")
    }

    static var serverLogURL: URL {
        supportDirectory.appendingPathComponent("server.log")
    }

    /// CONFIG-RECOVERY: copy of the last config.json YappYapp wrote itself.
    static var lastSavedConfigURL: URL {
        supportDirectory.appendingPathComponent("config.json.last-good")
    }

    static var launchSmokeURL: URL {
        supportDirectory.appendingPathComponent("launch-smoke-ok")
    }

    static func rewriteLegacySupportPath(in path: String) -> String {
        path
            .replacingOccurrences(of: legacySupportDirectoryToken, with: supportDirectoryToken)
            .replacingOccurrences(of: legacySupportDirectory.path, with: supportDirectory.path)
    }

    static func defaultModelPath(for filename: String) -> String {
        if usesCustomApplicationSupportBase {
            return modelsDirectory.appendingPathComponent(filename).path
        }

        return "\(supportDirectoryToken)/models/\(filename)"
    }
}

final class ConfigStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // CORRUPT-CONFIG-RECOVER: observable so callers can tell that a corrupt
    // config.json was moved aside and replaced with fresh defaults. Sticky-true
    // for the lifetime of this store; callers just read it, no signature change.
    private(set) var didRestoreDefaultsFromCorruptConfig = false

    // MANAGED-PREFS: forced values from a configuration profile. Injectable so
    // tests never read the host Mac's preferences.
    private let managedPreferences: ManagedPreferencesReading
    /// Settings the profile forces, as of the last load().
    private(set) var lockedKeys: Set<ManagedConfigKey> = []
    private var managedOverrides = ManagedOverrides.none
    /// The user's own values as last read from or written to disk, before any
    /// managed override. save() restores locked fields from it.
    private var lastPersistedConfig: AppConfig?
    // CONFIG-RECOVERY: set once by a repair, handed out once by takeRecoveryNotice().
    private var pendingRecoveryNotice: ConfigRecoveryNotice?

    init(managedPreferences: ManagedPreferencesReading = SystemManagedPreferences.current) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        self.managedPreferences = managedPreferences
    }

    /// Returns the repair notice once, then nil until the next repair.
    func takeRecoveryNotice() -> ConfigRecoveryNotice? {
        defer { pendingRecoveryNotice = nil }
        return pendingRecoveryNotice
    }

    func prepareApplicationSupport() throws {
        try migrateLegacyApplicationSupportIfNeeded()

        try PrivateFile.ensureDirectory(at: AppPaths.supportDirectory)
        try PrivateFile.ensureDirectory(at: AppPaths.modelsDirectory)
        try PrivateFile.hardenDirectoryIfPresent(at: AppPaths.supportDirectory)
        try PrivateFile.hardenDirectoryIfPresent(at: AppPaths.modelsDirectory)
        try PrivateFile.hardenFileIfPresent(at: AppPaths.configURL)
        try PrivateFile.hardenFileIfPresent(at: AppPaths.glossaryURL)
        try PrivateFile.hardenFileIfPresent(at: AppPaths.serverLogURL)

        if !FileManager.default.fileExists(atPath: AppPaths.configURL.path) {
            try save(defaultConfigForCurrentInstall())
        } else {
            try rewriteLegacyPathsInConfigIfNeeded()
        }

        if !FileManager.default.fileExists(atPath: AppPaths.glossaryURL.path) {
            try Glossary.save(Glossary.defaultEntries, to: AppPaths.glossaryURL)
        }
    }

    func load() throws -> AppConfig {
        let data = try Data(contentsOf: AppPaths.configURL)
        // CONFIG-RECOVERY (YA-26): decode key by key. A damaged file is repaired
        // from the last saved copy where possible, moved aside, and rewritten.
        let outcome = ConfigRecovery.decode(
            data: data,
            installDefaults: defaultConfigForCurrentInstall(),
            lastSaved: { self.readLastSavedConfig() },
            hasPriorUse: { ConfigRecovery.hasPriorUse(in: AppPaths.supportDirectory) }
        )
        let persisted: AppConfig
        if outcome.isDamaged {
            persisted = try recoverFromDamagedConfig(outcome)
        } else {
            persisted = outcome.config
            if !FileManager.default.fileExists(atPath: AppPaths.lastSavedConfigURL.path) {
                try? PrivateFile.write(data, to: AppPaths.lastSavedConfigURL)
            }
        }
        lastPersistedConfig = persisted

        // MANAGED-PREFS: forced values win over config.json, on every load.
        managedOverrides = ManagedOverrides.read(from: managedPreferences)
        lockedKeys = managedOverrides.lockedKeys
        return managedOverrides.apply(to: persisted)
    }

    func save(_ config: AppConfig) throws {
        // MANAGED-PREFS: never write a forced value over the user's own choice.
        var toWrite = config
        if let lastPersistedConfig, !lockedKeys.isEmpty {
            toWrite = managedOverrides.restoringUserValues(in: config, from: lastPersistedConfig)
        }
        try writePersisted(toWrite)
    }

    private func writePersisted(_ config: AppConfig) throws {
        let data = try encoder.encode(config)
        try PrivateFile.write(data, to: AppPaths.configURL)
        // CONFIG-RECOVERY: the last good copy is what a later repair restores.
        try? PrivateFile.write(data, to: AppPaths.lastSavedConfigURL)
        lastPersistedConfig = config
    }

    private func readLastSavedConfig() -> AppConfig? {
        guard let data = try? Data(contentsOf: AppPaths.lastSavedConfigURL),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return nil
        }
        let outcome = ConfigRecovery.decode(
            data: data,
            installDefaults: defaultConfigForCurrentInstall(),
            lastSaved: { nil }
        )
        return outcome.isDamaged ? nil : outcome.config
    }

    func defaultConfigForCurrentInstall() -> AppConfig {
        var config = AppConfig.defaultConfig

        if let resourceURL = Bundle.main.resourceURL {
            let bundledCLI = resourceURL
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("whisper-cli")

            let cliCandidates = [
                bundledCLI.path,
                "/opt/homebrew/bin/whisper-cli",
                "/usr/local/bin/whisper-cli"
            ]

            if let cliPath = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                config.whisperBinaryPath = cliPath
            }

            let bundledModel = resourceURL
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("ggml-large-v3-turbo.bin")

            if FileManager.default.fileExists(atPath: bundledModel.path) {
                config.modelPath = bundledModel.path
            }
        }

        return config
    }

    // CORRUPT-CONFIG-RECOVER: preserve the damaged file for forensics, then
    // write the repaired config so the very next load() succeeds.
    private func recoverFromDamagedConfig(_ outcome: ConfigDecodeOutcome) throws -> AppConfig {
        let fileManager = FileManager.default
        let backupURL = nextAvailableCorruptBackupURL()

        // Best-effort: keep the damaged bytes if we can move them aside; if the
        // move fails, delete the file so the repaired config can still be
        // written rather than re-corrupting the app into the same dead-end.
        var keptBackup = false
        do {
            try fileManager.moveItem(at: AppPaths.configURL, to: backupURL)
            try PrivateFile.hardenFileIfPresent(at: backupURL)
            keptBackup = true
        } catch {
            try? fileManager.removeItem(at: AppPaths.configURL)
        }

        try writePersisted(outcome.config)
        didRestoreDefaultsFromCorruptConfig = true
        pendingRecoveryNotice = ConfigRecoveryNotice(
            backupFileName: keptBackup ? backupURL.lastPathComponent : nil,
            restoredFromLastSave: outcome.restoredFromLastSave,
            downloadsTurnedOff: outcome.downloadsFailedClosed
        )

        let reason = outcome.wasUnreadable
            ? "unreadable"
            : "damaged keys: \((outcome.invalidKeys + outcome.missingCoreKeys).joined(separator: ","))"
        FileHandle.standardError.write(Data(
            "YappYapp non-fatal: config.json was \(reason); moved aside to \(backupURL.lastPathComponent) and repaired\n".utf8
        ))

        return outcome.config
    }

    private func nextAvailableCorruptBackupURL() -> URL {
        let fileManager = FileManager.default
        let directory = AppPaths.configURL.deletingLastPathComponent()
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent("config.json.corrupt-\(index)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func migrateLegacyApplicationSupportIfNeeded() throws {
        let fileManager = FileManager.default
        let current = AppPaths.supportDirectory
        let legacy = AppPaths.legacySupportDirectory

        guard fileManager.fileExists(atPath: legacy.path) else {
            return
        }

        if !fileManager.fileExists(atPath: current.path) {
            try fileManager.moveItem(at: legacy, to: current)
            return
        }

        try migrateMissingContents(from: legacy, to: current)
    }

    private func migrateMissingContents(from legacy: URL, to current: URL) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for item in items {
            let destination = current.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            let destinationExists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)

            if destinationExists && isDirectory.boolValue {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    try migrateMissingContents(from: item, to: destination)
                }
                continue
            }

            guard !destinationExists else { continue }
            try fileManager.moveItem(at: item, to: destination)
        }

        // LEGACY-MIGRATION-CLEANUP: mirror the whole-directory move branch by
        // dropping the source directory once it has been fully drained. Without
        // this, an emptied YappYappLegacy (or any emptied subdirectory) is
        // re-walked on every launch. Kept only when nothing remains, so skipped
        // conflicts or un-migrated hidden files preserve the directory.
        removeDirectoryIfEmpty(legacy)
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        let fileManager = FileManager.default
        // No .skipsHiddenFiles here: hidden files are never migrated, so treating
        // them as "empty" would delete un-migrated data. Any remaining entry
        // keeps the directory in place.
        let remaining = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        guard remaining.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    private func rewriteLegacyPathsInConfigIfNeeded() throws {
        var config = try load()
        // LEGACY-MIGRATION-CLEANUP: rewrite BOTH filesystem paths that can point
        // into the old YappYappLegacy tree, not just modelPath. A bundled
        // whisperBinaryPath living under legacy would otherwise stay stale.
        let rewrittenModelPath = AppPaths.rewriteLegacySupportPath(in: config.modelPath)
        let rewrittenBinaryPath = AppPaths.rewriteLegacySupportPath(in: config.whisperBinaryPath)
        guard rewrittenModelPath != config.modelPath
            || rewrittenBinaryPath != config.whisperBinaryPath else { return }

        config.modelPath = rewrittenModelPath
        config.whisperBinaryPath = rewrittenBinaryPath
        try save(config)
    }
}

extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
