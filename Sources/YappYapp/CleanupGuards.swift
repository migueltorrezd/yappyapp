import Foundation
import NaturalLanguage

// LLM-CLEANUP: the deterministic halves of the cleanup pass. Both are pure so
// the self-tests pin them without a model.

// MARK: - Self-corrections

/// Applies explicit spoken corrections before the model sees the text:
/// "ship it on monday, no wait, on tuesday" becomes "ship it on tuesday".
///
/// PROMPT-TUNING LOG (2026-07-05) found that Qwen 2.5 1.5B resolves
/// corrections to the wrong side, so the model still keeps them verbatim and
/// this rule-based pass does the resolving instead. It is conservative on
/// purpose: it acts only on an explicit marker ("no wait", "sorry, I meant",
/// "non, je veux dire", "no, espera", "nee, wacht", "nein, warte"), and only
/// when it can tell what the correction replaces. Anything ambiguous stays as
/// spoken.
enum SelfCorrection {
    /// Marker phrases, normalized (lowercase, no accents, no punctuation).
    /// Longer phrases first, so "no wait i meant" wins over "no wait".
    static let markers: [[String]] = [
        // English
        ["no", "wait", "i", "meant"],
        ["no", "wait", "i", "mean"],
        ["no", "sorry", "i", "meant"],
        ["sorry", "i", "meant"],
        ["no", "i", "meant"],
        ["no", "i", "mean"],
        ["no", "wait"],
        // French
        ["non", "attends", "je", "veux", "dire"],
        ["non", "je", "veux", "dire"],
        ["non", "je", "voulais", "dire"],
        ["pardon", "je", "voulais", "dire"],
        ["pardon", "je", "veux", "dire"],
        ["non", "attends"],
        // Spanish
        ["no", "espera", "quise", "decir"],
        ["perdon", "quise", "decir"],
        ["no", "quise", "decir"],
        ["no", "espera"],
        // Dutch
        ["nee", "wacht", "ik", "bedoel"],
        ["nee", "ik", "bedoel"],
        ["nee", "wacht"],
        // German
        ["nein", "warte", "ich", "meine"],
        ["nein", "ich", "meine"],
        ["nein", "warte"],
    ].sorted { $0.count > $1.count }

    /// How far back (in words) a correction may reach for its anchor word.
    static let anchorReach = 6
    /// Without an anchor, only a correction this short replaces the same
    /// number of words before the marker.
    static let maxUnanchoredWords = 3

    static func resolve(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3 else { return text }
        var changed = false
        // A dictation rarely holds more than a couple of corrections; the cap
        // keeps a pathological input from looping.
        for _ in 0..<4 {
            guard let next = resolveOnce(tokens) else { break }
            tokens = next
            changed = true
        }
        return changed ? tokens.joined(separator: " ") : text
    }

    static func normalize(_ token: String) -> String {
        token
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    private static let pauseMarks: Set<Character> = [",", ";", ":", ".", "!", "?", "…", "-", "\u{2014}"]

    private static func endsSentence(_ token: String) -> Bool {
        token.last.map { sentenceEnd.contains($0) } ?? false
    }

    private static func resolveOnce(_ tokens: [String]) -> [String]? {
        let normalized = tokens.map(normalize)
        guard tokens.count >= 3 else { return nil }

        for index in 1..<tokens.count {
            for marker in markers {
                let markerEnd = index + marker.count
                guard markerEnd < tokens.count,
                      Array(normalized[index..<markerEnd]) == marker else { continue }

                // What was said before the marker: the current sentence, or
                // the previous one when the marker opens a new sentence.
                var clauseStart = 0
                if index >= 2 {
                    for position in stride(from: index - 2, through: 0, by: -1) where endsSentence(tokens[position]) {
                        clauseStart = position + 1
                        break
                    }
                }
                let before = index - clauseStart
                guard before > 0 else { continue }

                // The correction runs to the end of its sentence.
                var correctionEnd = markerEnd
                while correctionEnd < tokens.count {
                    correctionEnd += 1
                    if endsSentence(tokens[correctionEnd - 1]) { break }
                }
                guard correctionEnd > markerEnd else { continue }

                var replaceStart: Int?
                // Anchor: the correction repeats a word it replaces
                // ("on monday, no wait, on tuesday").
                let anchor = normalized[markerEnd]
                if !anchor.isEmpty {
                    let reach = max(clauseStart, index - anchorReach)
                    for position in stride(from: index - 1, through: reach, by: -1) where normalized[position] == anchor {
                        replaceStart = position
                        break
                    }
                }

                // No anchor: a short correction after an audible pause
                // replaces the same number of words ("John, no wait, Mary").
                if replaceStart == nil {
                    let pausedBefore = tokens[index - 1].last.map { pauseMarks.contains($0) } ?? false
                    var head = 0
                    for position in markerEnd..<correctionEnd {
                        head += 1
                        if let last = tokens[position].last, pauseMarks.contains(last) { break }
                    }
                    guard pausedBefore, head <= maxUnanchoredWords, head <= before else { continue }
                    replaceStart = index - head
                }

                guard let start = replaceStart else { continue }
                var correction = Array(tokens[markerEnd...])
                // A correction that replaces the start of a sentence takes
                // over its capital letter.
                if start == clauseStart,
                   let first = tokens[start].first, first.isUppercase,
                   let replacementFirst = correction[0].first, replacementFirst.isLowercase {
                    correction[0] = replacementFirst.uppercased() + correction[0].dropFirst()
                }
                return Array(tokens[..<start]) + correction
            }
        }
        return nil
    }
}

// MARK: - Acceptance

/// Why a model rewrite was thrown away in favor of the raw transcript.
enum CleanupRejection: String, Equatable, Sendable {
    case empty
    case lengthDrift
    case newWords
    case droppedWords
    case languageChanged
    case answered
    case promptLeak

    /// Short, plain reason for the status line.
    var reason: String {
        switch self {
        case .empty: L10n.tr("cleanup returned nothing")
        case .lengthDrift: L10n.tr("cleanup changed the length too much")
        case .newWords: L10n.tr("cleanup added words you didn't say")
        case .droppedWords: L10n.tr("cleanup dropped words you said")
        case .languageChanged: L10n.tr("cleanup switched language")
        case .answered: L10n.tr("cleanup replied instead of cleaning")
        case .promptLeak: L10n.tr("cleanup echoed its instructions")
        }
    }
}

/// The rewrite is only trusted when it still is the same dictation, tidied:
/// mostly the same words, the same language, a sane length, and no reply
/// from an assistant. Anything else falls back to the raw transcript.
enum CleanupAcceptance {
    struct Limits: Equatable {
        var minLengthRatio: Double
        var maxLengthRatio: Double
        /// Share of the rewrite's words that were never spoken.
        var maxNewWordShare: Double
        /// Share of the spoken words (fillers aside) that must survive.
        var minRetainedShare: Double
    }

    static func limits(for mode: CleanupMode) -> Limits {
        switch mode {
        case .verbatim, .clean:
            Limits(minLengthRatio: 0.35, maxLengthRatio: 1.6, maxNewWordShare: 0.25, minRetainedShare: 0.7)
        case .email:
            Limits(minLengthRatio: 0.35, maxLengthRatio: 1.8, maxNewWordShare: 0.25, minRetainedShare: 0.7)
        case .list:
            Limits(minLengthRatio: 0.3, maxLengthRatio: 1.8, maxNewWordShare: 0.25, minRetainedShare: 0.65)
        case .notes:
            Limits(minLengthRatio: 0.25, maxLengthRatio: 1.6, maxNewWordShare: 0.25, minRetainedShare: 0.45)
        }
    }

    /// A handful of new words is normal (a fixed contraction, "-" bullets).
    static let newWordAllowance = 2

    /// Spoken hesitations the cleanup is meant to drop.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "ehm", "euh", "heu", "hmm", "mmm", "eh", "ah", "ahm", "ahh", "aeh",
    ]

    /// Openers of an assistant reply rather than a dictation.
    static let assistantOpeners: [[String]] = [
        ["sure"], ["certainly"], ["of", "course"], ["here", "is"], ["here", "s"], ["heres"],
        ["here", "are"], ["as", "an", "ai"], ["i", "m", "sorry"], ["im", "sorry"], ["i", "cannot"],
        ["i", "can", "t"], ["the", "cleaned"], ["cleaned", "transcript"], ["the", "transcript"],
        ["voici"], ["bien", "sur"], ["claro"], ["aqui", "esta"], ["aqui", "tienes"], ["natuurlijk"],
        ["hier", "ist"], ["gerne"],
    ]

    static let promptFragments = ["protected spellings", "transcript:", "dictation transcript cleaner"]

    static func words(_ text: String) -> [String] {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// `protectedTerms` are the user's WORDS. WORDS-NEAR-MISS: a spoken word
    /// the rewrite replaced with one of them, when the two sound alike, is a
    /// fix rather than a new word ("jenial" written "Genial"): it neither
    /// counts as added nor as dropped. Nothing else is loosened.
    ///
    /// NUMBERS: with a `numberLanguage` (a DIGITS or WORDS dictation), both
    /// sides are compared with every number in plain digits, so "twenty five"
    /// written "25" (or back) is the same word. Only the written form of a
    /// number is excused: a changed value still counts as new and dropped.
    static func evaluate(
        original: String,
        cleaned: String,
        mode: CleanupMode,
        protectedTerms: [String] = [],
        numberLanguage: NumberLanguage? = nil
    ) -> CleanupRejection? {
        var cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTrimmed.isEmpty else { return .empty }
        var originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return .empty }
        if let numberLanguage {
            originalTrimmed = NumberForms.canonical(originalTrimmed, language: numberLanguage)
            cleanedTrimmed = NumberForms.canonical(cleanedTrimmed, language: numberLanguage)
        }

        let limits = limits(for: mode)
        let ratio = Double(cleanedTrimmed.count) / Double(originalTrimmed.count)
        guard ratio >= limits.minLengthRatio, ratio <= limits.maxLengthRatio else { return .lengthDrift }

        let lowerCleaned = cleanedTrimmed.lowercased()
        let lowerOriginal = originalTrimmed.lowercased()
        if promptFragments.contains(where: { lowerCleaned.contains($0) && !lowerOriginal.contains($0) }) {
            return .promptLeak
        }

        let originalWords = words(originalTrimmed)
        let cleanedWords = words(cleanedTrimmed)
        guard !cleanedWords.isEmpty else { return .empty }

        // A spoken "sure" or "here is" near the start is the user's own.
        if let opener = assistantOpeners.first(where: { cleanedWords.starts(with: $0) }),
           !originalWords.prefix(opener.count + 3).contains(opener[0]) {
            return .answered
        }

        var spoken = Set(originalWords)
        let excused = excusedSubstitutions(original: originalWords, cleaned: cleanedWords, protectedTerms: protectedTerms)
        let newCount = cleanedWords.filter { !spoken.contains($0) && !excused.added.contains($0) }.count
        if newCount > newWordAllowance,
           Double(newCount) / Double(cleanedWords.count) > limits.maxNewWordShare {
            return .newWords
        }

        spoken.subtract(excused.replaced)
        let content = spoken.subtracting(fillers)
        if !content.isEmpty {
            let kept = Set(cleanedWords)
            let retained = Double(content.filter { kept.contains($0) }.count) / Double(content.count)
            if retained < limits.minRetainedShare { return .droppedWords }
        }

        if languageChanged(from: originalTrimmed, to: cleanedTrimmed, wordCount: originalWords.count) {
            return .languageChanged
        }
        return nil
    }

    /// The user's words the rewrite added in place of a spoken word that
    /// sounds like them, and the spoken words they replaced. Each added word
    /// must belong to a protected term, be missing from the transcript, and
    /// pair with a spoken word that is missing from the rewrite.
    static func excusedSubstitutions(
        original: [String],
        cleaned: [String],
        protectedTerms: [String]
    ) -> (added: Set<String>, replaced: Set<String>) {
        guard !protectedTerms.isEmpty else { return ([], []) }
        let protectedWords = Set(protectedTerms.flatMap { words($0) })
        let spoken = Set(original)
        let kept = Set(cleaned)
        let missing = original.filter { !kept.contains($0) && !fillers.contains($0) }
        var added = Set<String>()
        var replaced = Set<String>()
        for word in cleaned where !spoken.contains(word) && protectedWords.contains(word) {
            if let match = missing.first(where: { !replaced.contains($0) && GlossaryNearMiss.soundsAlike($0, word) }) {
                added.insert(word)
                replaced.insert(match)
            }
        }
        return (added, replaced)
    }

    /// Only a confident detection on both sides counts: short or mixed
    /// dictations are too ambiguous to judge, and the word checks above
    /// already catch most translations.
    static func languageChanged(from original: String, to cleaned: String, wordCount: Int) -> Bool {
        guard wordCount >= 6,
              let before = dominantLanguage(original),
              let after = dominantLanguage(cleaned) else { return false }
        return before != after
    }

    static func dominantLanguage(_ text: String, minimumConfidence: Double = 0.8) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return nil }
        return language
    }
}
