import Foundation

// LEARN-FROM-FIXES: after a dictation lands, YappYapp watches the text it just
// pasted for a few seconds. When the user retypes a misheard name ("jenial"
// becomes "Genial"), the fixed spelling becomes one of their WORDS. This file
// is the pure half: the word diff, the rules that decide what is worth
// learning, and the edits to the word list. AutoLearnWatcher.swift reads the
// field; nothing here touches the system.

enum AutoLearn {
    /// A fix is a word or a short phrase on both sides.
    static let maxPhraseWords = 3
    /// At most this many words are learned from one dictation.
    static let maxLearnsPerDictation = 3
    /// Longer dictations are not diffed (the alignment is quadratic).
    static let maxDiffWords = 400
    /// Below this many dictated words, any rewrite share is fine.
    static let rewriteMinimumWords = 4
    /// Changing more than this share of the dictated words is a rewrite,
    /// not a fix. Nothing is learned from a rewrite.
    static let rewriteShare = 0.5
    /// The fix must look like it replaces the misheard word: this similar
    /// in spelling, or the same first sound.
    static let minimumSimilarity = 0.3

    // MARK: - Words

    struct Word: Equatable {
        /// The word without the punctuation around it.
        let text: String
        /// The word as written ends a sentence (".", "!", "?").
        let endsSentence: Bool
    }

    /// Whitespace-separated words, punctuation trimmed off their edges. Each
    /// CJK character is a word of its own, so Chinese or Japanese text
    /// without spaces still lines up character by character.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            var latin = ""
            func flush(endsSentence: Bool) {
                let trimmed = trimPunctuation(latin)
                if !trimmed.isEmpty {
                    result.append(Word(text: trimmed, endsSentence: endsSentence))
                }
                latin = ""
            }
            for character in piece {
                if isCJK(character) {
                    flush(endsSentence: false)
                    result.append(Word(text: String(character), endsSentence: false))
                } else {
                    latin.append(character)
                }
            }
            let end = latin.trimmingCharacters(in: .whitespaces).last
            flush(endsSentence: end.map { ".!?。！？".contains($0) } ?? false)
        }
        return result
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
                return true
            default:
                return false
            }
        }
    }

    static func trimPunctuation(_ text: String) -> String {
        let edges = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
            .subtracting(CharacterSet(charactersIn: "#+$%&"))
        return text.trimmingCharacters(in: edges)
    }

    // MARK: - Diff

    /// One replaced stretch: what YappYapp pasted and what the user wrote.
    struct Substitution: Equatable {
        let heard: [String]
        let fixed: [String]
        /// The first fixed word opens a sentence.
        let fixedStartsSentence: Bool
    }

    struct Diff: Equatable {
        let substitutions: [Substitution]
        /// Dictated words the user changed or removed.
        let changedWords: Int
        let dictatedWords: Int
    }

    /// Word-level alignment (longest common subsequence) of the pasted text
    /// and the same stretch after the user's edits. Pure insertions and
    /// deletions are counted but are not substitutions.
    static func diff(inserted: String, edited: String) -> Diff? {
        let before = words(inserted)
        let after = words(edited)
        guard !before.isEmpty, before.count <= maxDiffWords, after.count <= maxDiffWords * 2 else { return nil }

        let n = before.count, m = after.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = before[i].text == after[j].text
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var substitutions: [Substitution] = []
        var changed = 0
        var i = 0, j = 0
        var heard: [String] = []
        var fixed: [Word] = []
        var fixedStart = 0
        var atRegionStart = true
        func close(atRegionEnd: Bool) {
            defer { heard = []; fixed = []; atRegionStart = false }
            changed += heard.count
            guard !heard.isEmpty, !fixed.isEmpty else { return }
            var fixedWords = fixed
            // Text typed right after (or before) the dictation lands in the
            // same stretch as the last (or first) word's fix: keep the part
            // that lines up with what was dictated.
            if fixedWords.count > heard.count, heard.count <= maxPhraseWords {
                if atRegionEnd, !atRegionStart {
                    fixedWords = Array(fixedWords.prefix(heard.count))
                } else if atRegionStart, !atRegionEnd {
                    fixedStart += fixedWords.count - heard.count
                    fixedWords = Array(fixedWords.suffix(heard.count))
                }
            }
            let startsSentence = fixedStart == 0 || after[fixedStart - 1].endsSentence
            substitutions.append(Substitution(heard: heard, fixed: fixedWords.map(\.text), fixedStartsSentence: startsSentence))
        }
        while i < n || j < m {
            if i < n, j < m, before[i].text == after[j].text {
                if !heard.isEmpty || !fixed.isEmpty { close(atRegionEnd: false) }
                atRegionStart = false
                i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                if fixed.isEmpty { fixedStart = j }
                fixed.append(after[j]); j += 1
            } else {
                heard.append(before[i].text); i += 1
            }
        }
        if !heard.isEmpty || !fixed.isEmpty { close(atRegionEnd: true) }
        return Diff(substitutions: substitutions, changedWords: changed, dictatedWords: n)
    }

    // MARK: - Rules

    enum Rejection: Equatable {
        case tooLong
        case caseOrPunctuationOnly
        case notANameOrTerm
        case addressNumberOrFile
        case dictionaryWord
        case notSimilar
        case neverLearn
        case alreadyKnown
        case rewrite
    }

    enum Change: Equatable {
        /// A new word, with the misheard spelling as its "sounds like" when
        /// that spelling is safe to swap.
        case addWord(canonical: String, variant: String?)
        /// The user's own word, with one more "sounds like" spelling.
        case addVariant(canonical: String, variant: String)
    }

    struct Proposal: Equatable {
        let heard: String
        let fixed: String
        let change: Change

        var canonical: String {
            switch change {
            case .addWord(let canonical, _), .addVariant(let canonical, _): canonical
            }
        }
    }

    /// The words worth learning from one dictation's fixes, in text order.
    static func proposals(
        inserted: String,
        edited: String,
        entries: [GlossaryEntry],
        neverLearn: Set<String>,
        lexicon: any WordLexicon
    ) -> [Proposal] {
        guard let diff = diff(inserted: inserted, edited: edited) else { return [] }
        if diff.dictatedWords >= rewriteMinimumWords,
           Double(diff.changedWords) / Double(diff.dictatedWords) > rewriteShare {
            return []
        }
        var result: [Proposal] = []
        var known = entries
        for substitution in diff.substitutions {
            guard case .success(let proposal) = evaluate(substitution, entries: known, neverLearn: neverLearn, lexicon: lexicon) else { continue }
            guard !result.contains(where: { GlossaryNearMiss.fold($0.canonical) == GlossaryNearMiss.fold(proposal.canonical) }) else { continue }
            result.append(proposal)
            known = applying(proposal, to: known)
            if result.count == maxLearnsPerDictation { break }
        }
        return result
    }

    /// Why one substitution is or is not learned.
    static func evaluate(
        _ substitution: Substitution,
        entries: [GlossaryEntry],
        neverLearn: Set<String>,
        lexicon: any WordLexicon
    ) -> Result<Proposal, RejectionError> {
        func reject(_ reason: Rejection) -> Result<Proposal, RejectionError> { .failure(RejectionError(reason: reason)) }

        let heardWords = substitution.heard, fixedWords = substitution.fixed
        guard (1...maxPhraseWords).contains(heardWords.count), (1...maxPhraseWords).contains(fixedWords.count) else {
            return reject(.tooLong)
        }
        let heard = heardWords.joined(separator: " ")
        let fixed = fixedWords.joined(separator: " ")

        if looksLikeAddressNumberOrFile(fixed) { return reject(.addressNumberOrFile) }
        if spelling(heardWords) == spelling(fixedWords) { return reject(.caseOrPunctuationOnly) }
        guard let first = fixedWords.first, let last = fixedWords.last,
              isNameOrTerm(first), isNameOrTerm(last) else { return reject(.notANameOrTerm) }

        let fixedIsDictionary = fixedWords.allSatisfy { lexicon.isWord($0) }
        let heardIsDictionary = heardWords.allSatisfy { lexicon.isWord($0) }
        if fixedIsDictionary {
            // A capitalized everyday word ("Genial") is a name only when the
            // engine could not even spell it ("jenial") and it is not just
            // the start of a sentence.
            guard !heardIsDictionary, !substitution.fixedStartsSentence else { return reject(.dictionaryWord) }
        }

        let similarity = GlossaryNearMiss.similarity(heard, fixed)
        let sameStart = PhoneticKey.key(heard).first == PhoneticKey.key(fixed).first
            || GlossaryNearMiss.fold(heard).first == GlossaryNearMiss.fold(fixed).first
        guard similarity >= minimumSimilarity || sameStart else { return reject(.notSimilar) }

        let fixedKey = GlossaryNearMiss.fold(fixed)
        guard !neverLearn.contains(fixedKey) else { return reject(.neverLearn) }

        let variantUsable = !heardIsDictionary
            && GlossaryVariantSafety.isSafe(heard)
            && !entries.contains { entry in
                entry.variants.contains { GlossaryNearMiss.fold($0) == GlossaryNearMiss.fold(heard) }
                    || GlossaryNearMiss.fold(entry.canonical) == GlossaryNearMiss.fold(heard)
            }
        let variant = variantUsable ? heard.lowercased() : nil

        if let existing = entries.first(where: { GlossaryNearMiss.fold($0.canonical) == fixedKey }) {
            guard existing.canonical == fixed, let variant,
                  !neverLearn.contains(pairKey(heard: heard, canonical: fixed)) else {
                return reject(.alreadyKnown)
            }
            return .success(Proposal(heard: heard, fixed: fixed, change: .addVariant(canonical: fixed, variant: variant)))
        }
        return .success(Proposal(heard: heard, fixed: fixed, change: .addWord(canonical: fixed, variant: variant)))
    }

    struct RejectionError: Error, Equatable {
        let reason: Rejection
    }

    /// Letters and digits of each word, lower case, words kept apart: equal
    /// for a case or punctuation change, different for a split or joined
    /// word ("yappy app" and "YappYapp").
    static func spelling(_ words: [String]) -> String {
        words
            .map { String($0.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
            .joined(separator: " ")
    }

    /// Capitalized ("Genial"), capitals inside ("YappYapp", "iOS"), or
    /// letters with digits ("GPT-5", "M4").
    static func isNameOrTerm(_ word: String) -> Bool {
        let characters = Array(word)
        guard let first = characters.first(where: { $0.isLetter }) else { return false }
        let hasDigit = characters.contains { $0.isNumber }
        if first.isUppercase { return true }
        if characters.dropFirst().contains(where: { $0.isUppercase }) { return true }
        return hasDigit && characters.contains { $0.isLetter }
    }

    static func looksLikeAddressNumberOrFile(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("@") || lower.contains("://") || lower.hasPrefix("www.") || lower.contains("/") || lower.contains("\\") {
            return true
        }
        if !text.contains(where: { $0.isLetter }) { return true }
        if text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }) {
            return true
        }
        // name.ext: report.pdf, notes.md, whisper.cpp
        if text.range(of: #"^[^\s.]+\.[A-Za-z0-9]{1,5}$"#, options: .regularExpression) != nil,
           let dot = text.lastIndex(of: "."), text[text.index(after: dot)...].contains(where: { $0.isLetter }) {
            return true
        }
        return false
    }

    // MARK: - Word list edits

    /// The never-learn key of a learned word.
    static func blockKey(canonical: String) -> String {
        GlossaryNearMiss.fold(canonical)
    }

    /// The never-learn key of one "sounds like" spelling of a word.
    static func pairKey(heard: String, canonical: String) -> String {
        GlossaryNearMiss.fold(heard) + "\u{2192}" + GlossaryNearMiss.fold(canonical)
    }

    static func applying(_ proposal: Proposal, to entries: [GlossaryEntry]) -> [GlossaryEntry] {
        switch proposal.change {
        case .addWord(let canonical, let variant):
            guard !entries.contains(where: { GlossaryNearMiss.fold($0.canonical) == GlossaryNearMiss.fold(canonical) }) else {
                return entries
            }
            return [GlossaryEntry(canonical: canonical, variants: variant.map { [$0] } ?? [], notes: nil, learned: true)] + entries
        case .addVariant(let canonical, let variant):
            return entries.map { entry in
                guard entry.canonical == canonical,
                      !entry.variants.contains(where: { GlossaryNearMiss.fold($0) == GlossaryNearMiss.fold(variant) }) else { return entry }
                var updated = entry
                updated.variants.append(variant)
                return updated
            }
        }
    }

    /// UNDO: the word list without what `proposal` added, and the key that
    /// keeps it from being learned again.
    static func undoing(_ proposal: Proposal, from entries: [GlossaryEntry]) -> (entries: [GlossaryEntry], blockKey: String) {
        switch proposal.change {
        case .addWord(let canonical, _):
            return (entries.filter { !($0.canonical == canonical && $0.isLearned) }, blockKey(canonical: canonical))
        case .addVariant(let canonical, let variant):
            let updated = entries.map { entry -> GlossaryEntry in
                guard entry.canonical == canonical else { return entry }
                var copy = entry
                copy.variants.removeAll { GlossaryNearMiss.fold($0) == GlossaryNearMiss.fold(variant) }
                return copy
            }
            return (updated, pairKey(heard: proposal.heard, canonical: canonical))
        }
    }

    /// Learned words the user deleted in WORDS, as never-learn keys.
    static func deletedLearnedWords(old: [GlossaryEntry], new: [GlossaryEntry]) -> [String] {
        let kept = Set(new.map { GlossaryNearMiss.fold($0.canonical) })
        return old
            .filter { $0.isLearned && !kept.contains(GlossaryNearMiss.fold($0.canonical)) }
            .map { blockKey(canonical: $0.canonical) }
    }
}

// MARK: - The field region

/// Where the pasted text sits in a field, and how it reads after the user's
/// edits. Offsets are UTF-16, like Accessibility ranges.
enum AutoLearnRegion {
    /// The pasted stretch as it reads now, or nil when the text around it
    /// changed (the user went beyond what YappYapp pasted).
    static func edited(original: String, location: Int, length: Int, current: String) -> String? {
        let before = original as NSString
        guard location >= 0, length > 0, location + length <= before.length else { return nil }
        let prefix = before.substring(to: location)
        let suffix = before.substring(from: location + length)
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        let now = current as NSString
        guard now.length >= prefixLength + suffixLength,
              now.substring(to: prefixLength) == prefix,
              now.substring(from: now.length - suffixLength) == suffix else { return nil }
        return now.substring(with: NSRange(location: prefixLength, length: now.length - suffixLength - prefixLength))
    }

    /// Where a Cmd+V paste of `text` landed: right before the caret, else
    /// its only occurrence in the field. nil when it cannot be told apart.
    static func locate(_ text: String, in value: String, caret: Int?) -> Int? {
        let needle = text as NSString
        let haystack = value as NSString
        guard needle.length > 0, needle.length <= haystack.length else { return nil }
        if let caret, caret >= needle.length, caret <= haystack.length,
           haystack.substring(with: NSRange(location: caret - needle.length, length: needle.length)) == text {
            return caret - needle.length
        }
        let first = haystack.range(of: text)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: haystack.length - first.location - 1)
        guard haystack.range(of: text, options: [], range: rest).location == NSNotFound else { return nil }
        return first.location
    }
}

// MARK: - Never learn

/// Words the user deleted or undid after YappYapp learned them. Kept next
/// to the glossary in learn-never.json, as folded keys only.
enum NeverLearnList {
    static let limit = 500

    static func load(from url: URL = AppPaths.neverLearnURL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    /// The list with `keys` added, newest last, capped at `limit`.
    static func adding(_ keys: [String], to list: [String]) -> [String] {
        var result = list
        for key in keys where !key.isEmpty && !result.contains(key) {
            result.append(key)
        }
        return Array(result.suffix(limit))
    }

    static func save(_ keys: [String], to url: URL = AppPaths.neverLearnURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try PrivateFile.write(try encoder.encode(keys), to: url)
    }
}

/// The short message after a learn, and its UNDO.
struct LearnedWordNotice: Equatable, Identifiable {
    let id = UUID()
    let proposal: AutoLearn.Proposal

    var word: String { proposal.canonical }

    /// "Learned Genial."
    var message: String { L10n.tr("Learned %@.", word) }

    static func == (lhs: LearnedWordNotice, rhs: LearnedWordNotice) -> Bool {
        lhs.id == rhs.id
    }
}

enum LearnFromFixesCopy {
    static var settingTitle: String { L10n.tr("LEARN FROM MY FIXES") }
    static var settingCaption: String { L10n.tr("Reads only the text YappYapp just pasted, for a few seconds, on this Mac.") }
    static var learnedTag: String { L10n.tr("LEARNED") }
    static var learnedTagHelp: String { L10n.tr("YappYapp learned this word from a fix you made. Delete it and it won't come back.") }
    static var undo: String { L10n.tr("UNDO") }
    static var undoHint: String { L10n.tr("Removes the word YappYapp just learned") }
    static var undone: String { L10n.tr("Removed. YappYapp won't learn it again.") }
    static var notificationTitle: String { L10n.tr("YappYapp learned a word") }
    /// The word shows in the banner only when text in notifications is on.
    static func notificationBody(word: String, showText: Bool) -> String {
        showText
            ? L10n.tr("Learned %@ from your fix. Undo if that's wrong.", word)
            : L10n.tr("Learned a word from your fix. See it in WORDS, or undo here.")
    }
    static var notificationUndo: String { L10n.tr("Undo") }
}
