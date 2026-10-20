import Foundation

/// SNIPPETS: a spoken phrase that expands to stored text, for example
/// "my email address" becomes the address itself. Snippets run after the
/// glossary and voice commands, on the finished transcript, and only on an
/// exact phrase match with word boundaries on both sides.
struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case trigger
        case expansion
    }

    // A hand-edited or imported file may leave out the id; give it one
    // instead of refusing the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
    }
}

/// How a spoken phrase is compared and matched. Matching is case-insensitive
/// and treats any run of spaces as one space, but never folds accents, so
/// "café" and "cafe" stay different phrases in every language.
enum SnippetTrigger {
    static let maximumLength = 80
    static let maximumExpansionLength = 5_000
    /// Phrases in scripts written without spaces (Chinese, Japanese, Thai)
    /// count as safe from this many characters.
    static let minimumSpacelessLength = 2

    /// Comparison key: trimmed, lowercased, inner spaces collapsed, trailing
    /// sentence punctuation removed.
    static func normalized(_ phrase: String) -> String {
        let words = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: terminalPunctuation)
            .split(whereSeparator: \.isWhitespace)
        return words.joined(separator: " ").lowercased()
    }

    static func words(in phrase: String) -> [String] {
        phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static let terminalPunctuation = CharacterSet(charactersIn: ".!?,;:。！？、…")

    /// True when every letter belongs to a script that does not separate
    /// words with spaces, so word boundaries cannot be required around it.
    static func isSpaceless(_ phrase: String) -> Bool {
        var sawLetter = false
        for scalar in phrase.unicodeScalars where scalar.properties.isAlphabetic {
            sawLetter = true
            if !spacelessRanges.contains(where: { $0.contains(scalar.value) }) {
                return false
            }
        }
        return sawLetter
    }

    private static let spacelessRanges: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, // Thai, Lao
        0x1000...0x109F, // Myanmar
        0x1780...0x17FF, // Khmer
        0x3040...0x30FF, // Hiragana, Katakana
        0x3400...0x4DBF, // CJK Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFF66...0xFF9F, // Halfwidth Katakana
        0x20000...0x2FA1F // CJK Extensions B and later
    ]

    /// The regex body for one phrase: its words, escaped, joined by any run
    /// of whitespace. Nil for a phrase with no words.
    static func core(for phrase: String) -> String? {
        let parts = words(in: phrase.trimmingCharacters(in: terminalPunctuation))
        guard !parts.isEmpty else { return nil }
        return parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"\s+"#)
    }

    /// Boundaries on both sides: no letter, digit, apostrophe, hyphen or
    /// underscore may touch the phrase, so "adresse mail" never fires inside
    /// "l'adresse mail" or "e-adresse mail". Spaceless scripts have no word
    /// boundaries to test, so their phrases match anywhere.
    static func boundaries(for phrase: String) -> (lead: String, trail: String) {
        if isSpaceless(phrase) {
            return ("", "")
        }
        return (#"(?<![\p{L}\p{N}\p{M}'’\-_])"#, #"(?![\p{L}\p{N}\p{M}'’\-_])"#)
    }

    /// Why a phrase cannot fire safely, or nil when it can. Shared by the
    /// editor, the importer and the expander, so an old or hand-edited file
    /// can never rewrite ordinary speech either.
    static func safetyIssue(for phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.tr("Add the phrase you will say.") }
        if trimmed.count > maximumLength {
            return L10n.tr("Keep the phrase under %@ characters.", "\(maximumLength)")
        }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return L10n.tr("Use words, not only punctuation.")
        }
        if isSpaceless(trimmed) {
            return normalized(trimmed).count < minimumSpacelessLength
                ? L10n.tr("\"%@\" is too short. Normal speech would set it off.", trimmed)
                : nil
        }
        let parts = words(in: normalized(trimmed))
        if parts.count < 2 {
            return L10n.tr("Use at least two words so normal speech never sets it off.")
        }
        if parts.allSatisfy({ GlossaryVariantSafety.commonWords.contains($0.trimmingCharacters(in: .punctuationCharacters)) }) {
            return L10n.tr("Every word in \"%@\" is an everyday word. Pick a phrase you never say by accident.", trimmed)
        }
        return nil
    }
}

/// Inline validation for the snippet editor. A row with a problem shows it
/// and blocks saving; a row left completely empty is simply not saved.
enum SnippetDraftValidator {
    static func issue(
        trigger: String,
        expansion: String,
        otherTriggers: [String] = [],
        glossary: [GlossaryEntry] = []
    ) -> String? {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpansion = !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if trimmedTrigger.isEmpty {
            return hasExpansion ? L10n.tr("Add the phrase you will say.") : nil
        }
        if let issue = SnippetTrigger.safetyIssue(for: trimmedTrigger) {
            return issue
        }
        guard hasExpansion else { return L10n.tr("Add the text to write.") }
        if expansion.count > SnippetTrigger.maximumExpansionLength {
            return L10n.tr("Keep the text under 5,000 characters.")
        }
        let key = SnippetTrigger.normalized(trimmedTrigger)
        if otherTriggers.contains(where: { SnippetTrigger.normalized($0) == key }) {
            return L10n.tr("\"%@\" is already a snippet.", trimmedTrigger)
        }
        if let word = glossaryConflict(for: trimmedTrigger, in: glossary) {
            return L10n.tr("\"%@\" is already in your words as %@. Pick another phrase.", trimmedTrigger, word)
        }
        return nil
    }

    /// The glossary spelling a phrase collides with, if any. A phrase that is
    /// exactly a word's spelling or one of its sounds-like spellings would be
    /// rewritten by the glossary before snippets ever see it.
    static func glossaryConflict(for trigger: String, in glossary: [GlossaryEntry]) -> String? {
        let key = SnippetTrigger.normalized(trigger)
        for entry in glossary {
            let spellings = [entry.canonical] + entry.variants
            if spellings.contains(where: { SnippetTrigger.normalized($0) == key }) {
                return entry.canonical
            }
        }
        return nil
    }

    /// Issues for every row, keyed by row position. Each row is checked
    /// against the rows above it, so the first copy of a phrase stays clean.
    static func issues(
        for drafts: [(trigger: String, expansion: String)],
        glossary: [GlossaryEntry] = []
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, draft) in drafts.enumerated() {
            let earlier = drafts[..<index].map(\.trigger)
            if let issue = issue(trigger: draft.trigger, expansion: draft.expansion, otherTriggers: earlier, glossary: glossary) {
                result[index] = issue
            }
        }
        return result
    }

    static func isBlank(trigger: String, expansion: String) -> Bool {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The saved snippets, ready to expand a transcript. Immutable, so the
/// transcription Task can read a snapshot without racing a save.
final class SnippetLibrary: Sendable {
    let snippets: [Snippet]

    init(snippets: [Snippet]) {
        self.snippets = snippets
    }

    var count: Int { snippets.count }

    /// The phrases ready to match, with the regex that finds them. nil when
    /// there is nothing to expand.
    private struct Matcher {
        let usable: [Snippet]
        let forms: [(phrase: String, snippet: Int)]
        let regex: NSRegularExpression?
        let groupSnippet: [Int]
    }

    private func matcher(glossary: Glossary?) -> Matcher? {
        let usable = snippets.filter {
            SnippetTrigger.safetyIssue(for: $0.trigger) == nil
                && !$0.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return nil }

        var forms: [(phrase: String, snippet: Int)] = []
        var seen = Set<String>()
        for (index, snippet) in usable.enumerated() {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            var candidates = [trigger]
            if let glossary {
                candidates.append(glossary.applyingCorrections(to: trigger))
            }
            for candidate in candidates {
                let key = SnippetTrigger.normalized(candidate)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                forms.append((candidate, index))
            }
        }

        // Longest phrase first: at the same position the first alternative wins.
        forms.sort { SnippetTrigger.normalized($0.phrase).count > SnippetTrigger.normalized($1.phrase).count }
        var alternatives: [String] = []
        var groupSnippet: [Int] = []
        for form in forms {
            guard let core = SnippetTrigger.core(for: form.phrase) else { continue }
            let bounds = SnippetTrigger.boundaries(for: form.phrase)
            alternatives.append("(?:\(bounds.lead)(\(core))\(bounds.trail))")
            groupSnippet.append(form.snippet)
        }
        let regex = alternatives.isEmpty ? nil : try? NSRegularExpression(pattern: "(?i)" + alternatives.joined(separator: "|"))
        return Matcher(usable: usable, forms: forms, regex: regex, groupSnippet: groupSnippet)
    }

    /// Replaces every spoken phrase in `text` with its stored text, in one
    /// pass, so inserted text is never expanded again. The longest phrase
    /// wins where two overlap. When `glossary` is given, a phrase is also
    /// matched in the spelling the glossary turns it into, because the
    /// glossary has already run on the transcript.
    func expanding(_ text: String, glossary: Glossary? = nil) -> String {
        guard !text.isEmpty, let matcher = matcher(glossary: glossary) else { return text }

        // A dictation that is only the phrase gets the stored text exactly,
        // without the period the model adds after a short sentence.
        let wholeKey = SnippetTrigger.normalized(text)
        if let whole = matcher.forms.first(where: { SnippetTrigger.normalized($0.phrase) == wholeKey }) {
            return matcher.usable[whole.snippet].expansion
        }

        guard let regex = matcher.regex else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }),
                  matcher.groupSnippet.indices.contains(group - 1)
            else { continue }
            result.replaceCharacters(in: match.range, with: matcher.usable[matcher.groupSnippet[group - 1]].expansion)
        }
        return result as String
    }

    /// NUMBERS: where `expanding` would find a phrase, so the number pass
    /// (which runs just before it) leaves those words exactly as saved.
    func phraseRanges(in text: String, glossary: Glossary? = nil) -> [Range<String.Index>] {
        guard !text.isEmpty, let matcher = matcher(glossary: glossary) else { return [] }
        let wholeKey = SnippetTrigger.normalized(text)
        if matcher.forms.contains(where: { SnippetTrigger.normalized($0.phrase) == wholeKey }) {
            return [text.startIndex..<text.endIndex]
        }
        return (matcher.regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
            .compactMap { Range($0.range, in: text) }
    }
}

/// snippets.json in the app support folder: a JSON array of
/// {"id", "trigger", "expansion"}, written with private permissions.
enum SnippetStore {
    static func load(from url: URL) throws -> [Snippet] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try PrivateFile.hardenFileIfPresent(at: url)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Snippet].self, from: data)
    }

    static func save(_ snippets: [Snippet], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cleaned(snippets))
        try PrivateFile.write(data, to: url)
    }

    /// Trims the phrase and drops rows with no phrase or no text. The stored
    /// text keeps its inner line breaks and spacing.
    static func cleaned(_ snippets: [Snippet]) -> [Snippet] {
        snippets
            .map { Snippet(id: $0.id, trigger: $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines), expansion: $0.expansion) }
            .filter { !$0.trigger.isEmpty && !$0.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension AppPaths {
    static var snippetsURL: URL {
        supportDirectory.appendingPathComponent("snippets.json")
    }
}

/// Editable row in the WORDS tab snippet list.
struct SnippetDraft: Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String

    init(snippet: Snippet) {
        id = snippet.id
        trigger = snippet.trigger
        expansion = snippet.expansion
    }

    /// A new row asks for keyboard focus once it appears.
    var wantsFocus = false

    init(id: UUID = UUID(), trigger: String, expansion: String, wantsFocus: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.wantsFocus = wantsFocus
    }

    var snippet: Snippet {
        Snippet(id: id, trigger: trigger, expansion: expansion)
    }
}

/// Loads and saves snippets.json for the app and mirrors them into state.
/// A damaged file never blocks launch: it is kept aside and the app runs
/// with no snippets until the user saves new ones.
@MainActor
enum SnippetPersistence {
    static func reload(into state: YappYappState, from url: URL = AppPaths.snippetsURL) -> SnippetLibrary {
        do {
            let snippets = try SnippetStore.load(from: url)
            if state.snippets != snippets {
                state.snippets = snippets
            }
            return SnippetLibrary(snippets: snippets)
        } catch {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("snippets.json.unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            state.postFeedback(
                .error(L10n.tr("Your snippets file couldn't be read, so you have no snippets for now. A copy is saved as %@.", aside.lastPathComponent), topic: "snippets"),
                on: .words
            )
            state.snippets = []
            return SnippetLibrary(snippets: [])
        }
    }

    /// Saves and returns the new library, or nil after posting the error.
    static func save(
        _ snippets: [Snippet],
        state: YappYappState,
        to url: URL = AppPaths.snippetsURL,
        successMessage: String? = nil
    ) -> SnippetLibrary? {
        do {
            try SnippetStore.save(snippets, to: url)
            let saved = try SnippetStore.load(from: url)
            state.snippets = saved
            state.postFeedback(.success(
                successMessage ?? L10n.tr("Snippets saved. They work from your next dictation."),
                topic: "snippets"
            ), on: .words)
            return SnippetLibrary(snippets: saved)
        } catch {
            state.postFeedback(.error(L10n.tr("Snippets weren't saved. %@", error.localizedDescription), topic: "snippets"), on: .words)
            return nil
        }
    }
}
