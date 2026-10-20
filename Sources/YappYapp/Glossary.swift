import Foundation

struct GlossaryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String { canonical }
    var canonical: String
    var variants: [String]
    var notes: String?
    /// LEARN-FROM-FIXES: true when YappYapp added this word after the user
    /// corrected a dictation by hand. Absent (nil) for words the user typed,
    /// so older glossary files and older builds read the same JSON.
    var learned: Bool? = nil

    var isLearned: Bool { learned == true }
}

final class Glossary: Sendable {
    let entries: [GlossaryEntry]
    /// WORDS-NEAR-MISS: decides which transcript words are everyday words
    /// that a near miss must never rewrite.
    let lexicon: any WordLexicon

    static let defaultEntries = [
        GlossaryEntry(
            canonical: "YappYapp",
            variants: ["yap yap", "yapyap", "yapp yapp", "yappyapp"],
            notes: "Product name for the local dictation utility."
        ),
        GlossaryEntry(
            canonical: "Whisper",
            variants: ["wispr", "whispr", "wisper"],
            notes: "OpenAI local speech recognition model family."
        ),
        GlossaryEntry(
            canonical: "whisper.cpp",
            variants: ["whisper c p p", "whisper cpp", "whisper dot cpp"],
            notes: "Local runtime used by the app."
        ),
        GlossaryEntry(
            canonical: "Apple Silicon",
            variants: ["apple silicon", "m series", "m-series"],
            notes: "Apple arm64 chips."
        )
    ]

    var count: Int {
        entries.count
    }

    var canonicalTerms: [String] {
        entries.map(\.canonical)
    }

    init(entries: [GlossaryEntry], lexicon: any WordLexicon = SpellCheckerLexicon.shared) {
        self.entries = entries
        self.lexicon = lexicon
    }

    static func load(from url: URL, lexicon: any WordLexicon = SpellCheckerLexicon.shared) throws -> Glossary {
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([GlossaryEntry].self, from: data)
        return Glossary(entries: entries, lexicon: lexicon)
    }

    static func save(_ entries: [GlossaryEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cleanEntries = entries
            .map { entry in
                GlossaryEntry(
                    canonical: entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
                    variants: entry.variants
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty },
                    notes: entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                    learned: entry.learned == true ? true : nil
                )
            }
            .filter { !$0.canonical.isEmpty }

        let data = try encoder.encode(cleanEntries)
        try PrivateFile.write(data, to: url)
    }

    func promptPrefix(limit: Int = 40) -> String {
        let terms = canonicalTerms.prefix(limit).joined(separator: ", ")
        guard !terms.isEmpty else { return "" }
        return "Company vocabulary and exact spellings: \(terms)."
    }

    /// The "sounds like" swaps, then close misses of the user's words
    /// (WORDS-NEAR-MISS). Runs after every engine and again after cleanup.
    func applyingCorrections(to text: String) -> String {
        GlossaryNearMiss.apply(to: applyingVariants(to: text), entries: entries, lexicon: lexicon)
    }

    /// Only the exact "sounds like" swaps.
    func applyingVariants(to text: String) -> String {
        var corrected = text

        for entry in entries {
            for variant in entry.variants {
                let trimmedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                // YA-36: short variants ("jpt" for "GPT") now fire, but a
                // single character or an everyday word never does.
                guard GlossaryVariantSafety.isSafe(trimmedVariant) else { continue }
                // FIX glossaryCasing: skip only when the variant is an EXACT copy of the
                // canonical. A case-only difference (e.g. "yappyapp" -> "YappYapp") is a real
                // correction and must fire; the previous caseInsensitiveCompare killed it.
                guard trimmedVariant != entry.canonical else { continue }

                let pattern = GlossaryVariantSafety.pattern(for: trimmedVariant)

                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

                let range = NSRange(corrected.startIndex..<corrected.endIndex, in: corrected)
                // FIX glossaryTemplate: canonical is data, not a regex template. Escape any
                // "$"/"\\" so a canonical like "A$AP" is not expanded as a capture reference.
                corrected = regex.stringByReplacingMatches(
                    in: corrected,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.canonical)
                )
            }
        }

        return corrected
    }
}
