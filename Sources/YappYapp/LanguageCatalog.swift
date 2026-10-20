import Foundation

struct LanguageOption: Equatable, Identifiable {
    let code: String
    let menuLabel: String
    let compactLabel: String

    var id: String { code }
    var brutalLabel: String { compactLabel.uppercased() }
}

enum LanguageCatalog {
    // L10N: computed so "Auto-Detect" follows the app language.
    static var options: [LanguageOption] { [
        LanguageOption(code: "auto", menuLabel: L10n.tr("Auto-Detect"), compactLabel: L10n.tr("Auto")),
        LanguageOption(code: "en", menuLabel: "English", compactLabel: "EN"),
        LanguageOption(code: "fr", menuLabel: "Français", compactLabel: "FR"),
        LanguageOption(code: "es", menuLabel: "Español", compactLabel: "ES"),
        LanguageOption(code: "nl", menuLabel: "Nederlands", compactLabel: "NL")
    ] }

    static func menuLabel(for code: String) -> String? {
        options.first { $0.code == code }?.menuLabel
    }

    // ONBOARDING: the languages people say they speak. Wider than `options`
    // (the codes the dictation setting takes) because it only steers the
    // model pick. Names stay in their own language, like the app language
    // chips, so nobody needs a translation to find theirs.
    static let spokenLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "Français"), ("es", "Español"), ("nl", "Nederlands"),
        ("de", "Deutsch"), ("it", "Italiano"), ("pt", "Português"), ("pl", "Polski"),
        ("sv", "Svenska"), ("ru", "Русский"), ("uk", "Українська"), ("tr", "Türkçe"),
        ("ar", "العربية"), ("hi", "हिन्दी"), ("ja", "日本語"), ("zh", "中文"), ("ko", "한국어")
    ]

    /// "Deutsch, 日本語" in catalog order.
    static func spokenNames(for codes: Set<String>) -> String {
        spokenLanguages.filter { codes.contains($0.code) }.map(\.name).joined(separator: ", ")
    }
}
