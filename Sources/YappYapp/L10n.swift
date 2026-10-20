import Foundation

// L10N (YA-42): every user-facing string goes through this one helper. The
// English text is the key, so a string missing from a table falls back to the
// English the code already shows. Tables live in the SwiftPM resource bundle
// (Sources/YappYapp/Resources/<lang>.lproj), which package_app.sh copies into
// Contents/Resources. The helper never touches Bundle.module: its generated
// accessor traps when the bundle is not where SwiftPM expects it.

/// The in-app "App language" choice. `system` follows the Mac.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case fr
    case es
    case nl

    var id: String { rawValue }

    /// Unknown or missing stored values follow the system.
    init(configValue: String) {
        self = AppLanguage(rawValue: configValue) ?? .system
    }

    /// Chip label. Language names stay in their own language so a user who
    /// picked the wrong one can always find the way back.
    var chipLabel: String {
        switch self {
        case .system: L10n.tr("SYSTEM")
        case .en: "ENGLISH"
        case .fr: "FRANÇAIS"
        case .es: "ESPAÑOL"
        case .nl: "NEDERLANDS"
        }
    }
}

enum L10n {
    /// Languages with a full table. English is the base and the fallback.
    static let supportedLanguages = ["en", "fr", "es", "nl"]
    static let baseLanguage = "en"
    static let resourceBundleName = "YappYapp_YappYapp.bundle"

    private static let lock = NSLock()
    // Starts in English so tests, diagnostics and CLI flags read the same on
    // every Mac. The app calls `apply(_:)` once it has loaded the config.
    nonisolated(unsafe) private static var storedLanguage = baseLanguage
    nonisolated(unsafe) private static var tables: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var lprojBundles: [String: Bundle] = [:]
    nonisolated(unsafe) private static var storedResourceBundleURL: URL??

    /// The resolved language code in use, always one of `supportedLanguages`.
    static var language: String {
        lock.lock()
        defer { lock.unlock() }
        return storedLanguage
    }

    static var locale: Locale { Locale(identifier: language) }

    /// Applies the config value. `system` picks the first supported language
    /// in the Mac's preferred list, else English.
    @discardableResult
    static func apply(_ setting: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let resolved = resolve(setting, preferredLanguages: preferredLanguages)
        lock.lock()
        storedLanguage = resolved
        lock.unlock()
        return resolved
    }

    static func resolve(_ setting: String, preferredLanguages: [String]) -> String {
        let choice = AppLanguage(configValue: setting)
        if choice != .system {
            return choice.rawValue
        }
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
                ?? String(identifier.prefix(2))
            if supportedLanguages.contains(code) {
                return code
            }
        }
        return baseLanguage
    }

    // MARK: - Lookup

    /// The English text in the active language.
    static func tr(_ english: String) -> String {
        string(english, language: language)
    }

    /// A format key such as "Saves %@ snippets" filled with `args`.
    static func tr(_ englishFormat: String, _ args: String...) -> String {
        format(englishFormat, args, language: language)
    }

    /// A plural key from Localizable.stringsdict, such as "%lld words".
    static func plural(_ key: String, _ count: Int) -> String {
        plural(key, count, language: language)
    }

    /// A fixed line shown in one language, in the active one. Lines built
    /// from a format come back unchanged; the next status update fixes them.
    static func retranslate(_ text: String) -> String {
        for code in supportedLanguages {
            if let key = table(for: code).first(where: { $0.value == text })?.key {
                return tr(key)
            }
        }
        return text
    }

    static func string(_ english: String, language: String) -> String {
        if let value = table(for: language)[english] {
            return value
        }
        if language != baseLanguage, let value = table(for: baseLanguage)[english] {
            return value
        }
        return english
    }

    static func format(_ englishFormat: String, _ args: [String], language: String) -> String {
        let template = string(englishFormat, language: language)
        return String(format: template, locale: Locale(identifier: language), arguments: args.map { $0 as NSString })
    }

    static func plural(_ key: String, _ count: Int, language: String) -> String {
        let missing = "\u{0}missing"
        var template = lprojBundle(for: language)?.localizedString(forKey: key, value: missing, table: nil)
        if template == nil || template == missing {
            template = lprojBundle(for: baseLanguage)?.localizedString(forKey: key, value: missing, table: nil)
        }
        let locale = Locale(identifier: language)
        let filled: String
        if let template, template != missing {
            filled = String(format: template, locale: locale, count)
        } else {
            filled = String(format: key, locale: locale, count)
        }
        // %lld never groups digits; show 12,345 (or 12 345) like the rest of the UI.
        guard abs(count) >= 1000, let range = filled.range(of: String(count)) else { return filled }
        return filled.replacingCharacters(in: range, with: count.formatted(.number.locale(locale)))
    }

    // MARK: - Tables

    /// Every key and value of one language's Localizable.strings.
    static func table(for language: String) -> [String: String] {
        lock.lock()
        if let cached = tables[language] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var loaded: [String: String] = [:]
        if let url = lprojURL(for: language)?.appendingPathComponent("Localizable.strings"),
           let dictionary = NSDictionary(contentsOf: url) as? [String: String] {
            loaded = dictionary
        }

        lock.lock()
        tables[language] = loaded
        lock.unlock()
        return loaded
    }

    /// Raw plural rules of one language's Localizable.stringsdict.
    static func pluralTable(for language: String) -> [String: Any] {
        guard let url = lprojURL(for: language)?.appendingPathComponent("Localizable.stringsdict"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func lprojBundle(for language: String) -> Bundle? {
        lock.lock()
        if let cached = lprojBundles[language] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let url = lprojURL(for: language), let bundle = Bundle(url: url) else { return nil }
        lock.lock()
        lprojBundles[language] = bundle
        lock.unlock()
        return bundle
    }

    static func lprojURL(for language: String) -> URL? {
        guard let base = resourceBundleURL else { return nil }
        let manager = FileManager.default
        // SwiftPM writes either a flat bundle or one with Contents/Resources.
        for folder in [base, base.appendingPathComponent("Contents/Resources")] {
            let candidate = folder.appendingPathComponent("\(language).lproj")
            if manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// The SwiftPM resource bundle, found the same way in the packaged app
    /// (Contents/Resources), a debug build (next to the binary) and swift test.
    static var resourceBundleURL: URL? {
        lock.lock()
        if let cached = storedResourceBundleURL {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = resourceBundleCandidates().first { FileManager.default.fileExists(atPath: $0.path) }
        lock.lock()
        storedResourceBundleURL = .some(found)
        lock.unlock()
        return found
    }

    static func resourceBundleCandidates() -> [URL] {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL {
            folders.append(resources)
        }
        folders.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            folders.append(executable.deletingLastPathComponent())
        }
        // swift test: the test bundle sits next to the resource bundle.
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            folders.append(bundle.bundleURL.deletingLastPathComponent())
        }
        var candidates = folders.map { $0.appendingPathComponent(resourceBundleName) }
        #if DEBUG
        // Last resort for debug runs (swift test helpers): the source tables.
        candidates.append(
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")
        )
        #endif
        return candidates
    }
}
