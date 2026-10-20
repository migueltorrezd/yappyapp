import Foundation

// L10N (YA-42): read-only check that a build can find its translations.
// Kept in packaged builds so release verification can run it without the UI.
enum L10nDiagnostics {
    static func statusLines() -> [String] {
        var lines = ["l10n.bundle=\(L10n.resourceBundleURL?.path ?? "missing")"]
        for language in L10n.supportedLanguages {
            lines.append("l10n.\(language).strings=\(L10n.table(for: language).count)")
            lines.append("l10n.\(language).plurals=\(L10n.pluralTable(for: language).count)")
        }
        return lines
    }

    static func printStatus() -> Never {
        let lines = statusLines()
        print(lines.joined(separator: "\n"))
        let complete = L10n.supportedLanguages.allSatisfy { !L10n.table(for: $0).isEmpty }
        exit(complete ? 0 : 1)
    }
}
