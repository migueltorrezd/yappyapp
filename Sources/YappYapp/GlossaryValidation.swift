import Foundation

/// YA-36: decides which "sounds like" spellings may rewrite a transcript.
/// Short spellings are allowed (a misheard "jpt" for "GPT" is a real fix),
/// but a single character or an everyday function word would rewrite normal
/// sentences, so those never fire, even if an older glossary file has them.
enum GlossaryVariantSafety {
    static let minimumLength = 2
    /// Below this length a variant must also not touch an apostrophe or a
    /// hyphen, so "ai" never fires inside "l'ai" or "ai-je".
    static let strictBoundaryLength = 4

    /// Everyday short words in English, French, Spanish, Dutch and German.
    /// Swapping any of these would rewrite ordinary dictation.
    static let commonWords: Set<String> = [
        // English
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "for", "from",
        "go", "he", "her", "him", "his", "how", "i", "if", "in", "is", "it", "its", "me",
        "my", "no", "not", "of", "oh", "ok", "on", "or", "our", "she", "so", "than", "that",
        "the", "them", "then", "they", "this", "to", "too", "up", "us", "was", "we", "what",
        "who", "why", "will", "with", "yes", "you", "your", "all", "any", "had", "has",
        "have", "one", "two", "out", "now", "new", "get", "got", "see", "say", "way",
        // French
        "au", "aux", "ce", "ces", "dans", "de", "des", "du", "elle", "en", "est", "et",
        "il", "je", "la", "le", "les", "leur", "ma", "mais", "me", "mes", "mon", "ne",
        "nous", "ou", "où", "par", "pas", "pour", "qu", "que", "qui", "sa", "se", "ses",
        "son", "sur", "ta", "te", "tes", "toi", "ton", "tu", "un", "une", "vos", "vous",
        "oui", "non", "ça", "ai", "as", "va", "vu",
        // Spanish
        "al", "con", "del", "el", "ella", "es", "esa", "ese", "eso", "esta", "este", "los",
        "las", "lo", "mi", "mis", "muy", "para", "pero", "por", "se", "si", "sí", "su",
        "sus", "tú", "tu", "una", "uno", "y", "ya", "yo", "le", "les",
        // Dutch and German
        "het", "een", "ik", "jij", "wij", "zij", "dat", "die", "van", "op", "te", "niet",
        "ja", "nee", "der", "das", "den", "dem", "ein", "ist", "und", "ich", "du", "er",
        "wir", "ihr", "sie", "zu", "mit", "auf", "nicht"
    ]

    static func isSafe(_ variant: String) -> Bool {
        issue(for: variant) == nil
    }

    static func issue(for variant: String) -> String? {
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < minimumLength {
            return L10n.tr("\"%@\" is too short to swap safely.", trimmed)
        }
        if commonWords.contains(trimmed.lowercased()) {
            return L10n.tr("\"%@\" is an everyday word. Swapping it would rewrite normal sentences.", trimmed)
        }
        return nil
    }

    /// Word-boundary regex for one variant. Short variants also refuse to
    /// match next to an apostrophe or hyphen.
    static func pattern(for variant: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: variant)
        if variant.count < strictBoundaryLength {
            return #"(?i)(?<![\p{L}\p{N}'’\-])"# + escaped + #"(?![\p{L}\p{N}'’\-])"#
        }
        return #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
    }
}

/// YA-36: inline validation for the Words tab. Rows are never dropped
/// silently; each problem is shown under its row and blocks saving.
enum GlossaryDraftValidator {
    /// The problem with one row, or nil when it can be saved. A row with
    /// both fields empty is simply ignored on save, so it has no issue.
    static func issue(
        canonical: String,
        variantsText: String,
        otherCanonicals: [String] = []
    ) -> String? {
        let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = variantList(from: variantsText)

        if trimmedCanonical.isEmpty {
            return variants.isEmpty ? nil : L10n.tr("Add the spelling to write.")
        }

        let duplicate = otherCanonicals.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedCanonical) == .orderedSame
        }
        if duplicate {
            return L10n.tr("\"%@\" is already in your words.", trimmedCanonical)
        }

        for variant in variants {
            if let issue = GlossaryVariantSafety.issue(for: variant) {
                return issue
            }
        }
        return nil
    }

    /// Issues for every row, keyed by row position.
    static func issues(for drafts: [(canonical: String, variantsText: String)]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, draft) in drafts.enumerated() {
            let earlier = drafts[..<index].map(\.canonical)
            if let issue = issue(canonical: draft.canonical, variantsText: draft.variantsText, otherCanonicals: earlier) {
                result[index] = issue
            }
        }
        return result
    }

    /// True for a row the user never filled in. Saving skips these.
    static func isBlank(canonical: String, variantsText: String) -> Bool {
        canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && variantList(from: variantsText).isEmpty
    }

    static func variantList(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// WORDS: deleting a row is instant. X removes the saved word or snippet on
/// the spot (edits to other rows stay drafts until SAVE), and the sub-tab
/// counts follow the rows on screen, not the last save.
enum WordsDeletion {
    /// The saved words without the deleted row's word, or nil when the row
    /// was never saved and there is nothing to write.
    static func glossary(afterDeleting savedCanonical: String?, from saved: [GlossaryEntry]) -> [GlossaryEntry]? {
        guard let savedCanonical, saved.contains(where: { $0.canonical == savedCanonical }) else { return nil }
        return saved.filter { $0.canonical != savedCanonical }
    }

    /// The saved snippets without the deleted one, or nil for an unsaved row.
    static func snippets(afterDeleting id: UUID, from saved: [Snippet]) -> [Snippet]? {
        guard saved.contains(where: { $0.id == id }) else { return nil }
        return saved.filter { $0.id != id }
    }

    /// Rows the user sees with something in them. Blank new rows do not count.
    static func visibleCount(_ drafts: [GlossaryEntryDraft]) -> Int {
        drafts.filter { !GlossaryDraftValidator.isBlank(canonical: $0.canonical, variantsText: $0.variantsText) }.count
    }

    static func visibleCount(_ drafts: [SnippetDraft]) -> Int {
        drafts.filter { !SnippetDraftValidator.isBlank(trigger: $0.trigger, expansion: $0.expansion) }.count
    }

    /// True when `new` is `old` with exactly one item taken out, so the
    /// save reads as a delete.
    static func isSingleDeletion<T: Equatable>(old: [T], new: [T]) -> Bool {
        guard new.count + 1 == old.count else { return false }
        var remaining = new[...]
        var skipped = false
        for item in old {
            if let first = remaining.first, first == item {
                remaining = remaining.dropFirst()
            } else if !skipped {
                skipped = true
            } else {
                return false
            }
        }
        return remaining.isEmpty
    }
}

/// YA-52: the example spellings shown in empty Words fields. Both sounds-like
/// examples are misspellings that no real sentence contains, so a user who
/// copies them can never rewrite an ordinary word such as French "génial".
enum GlossaryPlaceholders {
    static let writeItAs = "Genial"
    static let soundsLike = "jenial, jen yal"
}
