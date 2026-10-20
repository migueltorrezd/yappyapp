import AppKit
import Foundation

// WORDS-NEAR-MISS: the deterministic half of "your words win". After the
// exact "sounds like" swaps, a transcript word that is a close miss of one of
// the user's words is written the user's way, even with cleanup off. It is
// conservative on purpose:
// - the miss must not be a real word in any dictation language (so the
//   Spanish adjective "genial" is never turned into the name "Genial"; that
//   call needs the sentence, and only the cleanup model reads sentences),
// - the user's word must be long enough (5 letters) to be distinctive,
// - the spellings must be very close: one or two letters apart, or the same
//   sound under a simple phonetic key and still close in letters.
// A case-only match ("kvellio" for "Kvellio") is fixed only when the lower
// case form is not a dictionary word either.

/// Answers "is this an everyday word?" for the dictation languages.
protocol WordLexicon: Sendable {
    func isWord(_ word: String) -> Bool
}

/// A fixed word list, for tests and previews.
struct StaticWordLexicon: WordLexicon {
    let words: Set<String>

    init(_ words: Set<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    func isWord(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}

/// The macOS spelling dictionaries, offline. A word counts as a dictionary
/// word when any of the dictation languages accepts it, as written or in
/// lower case. Calls are serialized behind a lock and cached; NSSpellChecker
/// answers from any thread this way.
final class SpellCheckerLexicon: WordLexicon, @unchecked Sendable {
    static let shared = SpellCheckerLexicon()

    private static let instancesLock = NSLock()
    nonisolated(unsafe) private static var instances: [String: SpellCheckerLexicon] = [:]

    /// One shared lexicon per dictation language setting.
    static func forDictationLanguage(_ code: String) -> SpellCheckerLexicon {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "auto" else { return shared }
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if let existing = instances[key] { return existing }
        let lexicon = SpellCheckerLexicon(languages: defaultLanguages(dictationLanguage: key))
        instances[key] = lexicon
        return lexicon
    }

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private var languages: [String]

    /// The dictation languages YappYapp is used in, plus the Mac's own.
    static func defaultLanguages(dictationLanguage: String = "auto") -> [String] {
        var wanted: [String] = []
        let code = dictationLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !code.isEmpty, code != "auto" { wanted.append(code) }
        for preferred in Locale.preferredLanguages.prefix(4) {
            wanted.append(String(preferred.prefix(2)).lowercased())
        }
        wanted += ["en", "fr", "es", "nl"]
        var seen = Set<String>()
        return wanted.filter { seen.insert($0).inserted }
    }

    init(languages: [String] = SpellCheckerLexicon.defaultLanguages()) {
        self.languages = languages
    }

    func isWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[trimmed] { return cached }
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        var known = false
        for language in languages where available.contains(language) {
            for form in Set([trimmed, trimmed.lowercased()]) {
                let range = checker.checkSpelling(
                    of: form, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                )
                if range.location == NSNotFound {
                    known = true
                    break
                }
            }
            if known { break }
        }
        if cache.count > 4_000 { cache.removeAll() }
        cache[trimmed] = known
        return known
    }
}

/// A rough sound key for English, French, Spanish and Dutch spellings:
/// soft c and g, ph, qu, x and z, v and w and b, doubled letters and vowel
/// runs collapse, h is silent. "jenial", "Jeanial" and "genial" share a key.
enum PhoneticKey {
    static func key(_ word: String) -> String {
        let letters = Array(GlossaryNearMiss.fold(word).filter(\.isLetter))
        guard !letters.isEmpty else { return "" }
        var output: [Character] = []
        var index = 0
        func peek(_ offset: Int) -> Character? {
            let position = index + offset
            return position < letters.count ? letters[position] : nil
        }
        func emit(_ character: Character) {
            if character == "a" {
                if output.last != "a" { output.append("a") }
            } else if output.last != character {
                output.append(character)
            }
        }
        while index < letters.count {
            let letter = letters[index]
            let next = peek(1)
            switch letter {
            case "a", "e", "i", "o", "u", "y":
                emit("a")
            case "p" where next == "h":
                emit("f"); index += 1
            case "s" where next == "c" && peek(2) == "h":
                emit("s"); index += 2
            case "s" where next == "h", "c" where next == "h":
                emit("s"); index += 1
            case "t" where next == "h", "g" where next == "h", "k" where next == "h":
                emit(letter == "t" ? "t" : (letter == "g" ? "g" : "k")); index += 1
            case "c" where next == "k":
                emit("k"); index += 1
            case "q" where next == "u":
                emit("k"); index += 1
            case "c":
                emit(next.map { "eiy".contains($0) } == true ? "s" : "k")
            case "q", "k":
                emit("k")
            case "g" where next == "u" && peek(2).map { "eiy".contains($0) } == true:
                emit("g"); index += 1
            case "g":
                emit(next.map { "eiy".contains($0) } == true ? "j" : "g")
            case "x":
                emit("k"); emit("s")
            case "z":
                emit("s")
            case "v", "w", "b":
                emit("b")
            case "h":
                break
            default:
                emit(letter)
            }
            index += 1
        }
        return String(output)
    }
}

enum GlossaryNearMiss {
    /// The user's word must have at least this many letters for a near miss
    /// to be fixed. Shorter words are too easy to hit by accident.
    static let minimumLetters = 5
    /// Multi-word user words longer than this are left to cleanup.
    static let maximumWords = 3

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 1 for identical spellings, 0 for nothing in common (folded).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = fold(lhs), b = fold(rhs)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance(a, b)) / Double(longest)
    }

    /// True when `heard` (spaces removed) is a close miss of `canonical`:
    /// within one letter (two from 8 letters up), or the same sound key and
    /// within a third of the letters. Case and accents never count.
    static func isCloseMiss(_ heard: String, of canonical: String) -> Bool {
        let heardFolded = fold(heard).filter { !$0.isWhitespace }
        let canonicalFolded = fold(canonical).filter { !$0.isWhitespace }
        guard !heardFolded.isEmpty, heard != canonical,
              abs(heardFolded.count - canonicalFolded.count) <= 2 else { return false }
        // Split ("zol trix"), accents or case only: the same letters.
        if heardFolded == canonicalFolded { return true }
        let distance = distance(heardFolded, canonicalFolded)
        let letterLimit = canonicalFolded.count >= 8 ? 2 : 1
        if distance <= letterLimit { return true }
        let soundLimit = max(2, canonicalFolded.count / 3)
        return distance <= soundLimit && PhoneticKey.key(heardFolded) == PhoneticKey.key(canonicalFolded)
    }

    /// Looser test for the cleanup guard: did the model swap a spoken word
    /// for the user's word it sounds like? Same sound key, or within a third
    /// of the letters.
    static func soundsAlike(_ heard: String, _ canonical: String) -> Bool {
        let heardFolded = fold(heard), canonicalFolded = fold(canonical)
        guard heardFolded.count >= 2, canonicalFolded.count >= 2 else { return false }
        if PhoneticKey.key(heardFolded) == PhoneticKey.key(canonicalFolded) { return true }
        return distance(heardFolded, canonicalFolded) <= max(1, canonicalFolded.count / 3)
    }

    struct Token: Equatable {
        let text: String
        let range: NSRange
    }

    /// Runs of letters and digits, with their UTF-16 ranges.
    static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        var result: [Token] = []
        var start: Int?
        var index = 0
        while index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let piece = ns.substring(with: range)
            let isWordPiece = piece.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if isWordPiece {
                if start == nil { start = range.location }
            } else if let open = start {
                let tokenRange = NSRange(location: open, length: range.location - open)
                result.append(Token(text: ns.substring(with: tokenRange), range: tokenRange))
                start = nil
            }
            index = range.location + range.length
        }
        if let open = start {
            let tokenRange = NSRange(location: open, length: ns.length - open)
            result.append(Token(text: ns.substring(with: tokenRange), range: tokenRange))
        }
        return result
    }

    private struct Match {
        let range: NSRange
        let canonical: String
        let distance: Int
    }

    /// The transcript with close misses of the user's words written their
    /// way. `lexicon` decides what an everyday word is.
    static func apply(to text: String, entries: [GlossaryEntry], lexicon: WordLexicon) -> String {
        let canonicals = entries
            .map { $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !canonicals.isEmpty, !text.isEmpty else { return text }
        var result = applyingCaseOnlyFixes(to: text, canonicals: canonicals, lexicon: lexicon)

        // Spans already spelled as one of the user's words or sounds-likes.
        let protected = Set(
            entries.flatMap { [$0.canonical] + $0.variants }
                .map { tokens(in: $0).map { fold($0.text) }.joined(separator: " ") }
        )
        let usable = canonicals.compactMap { canonical -> (String, Int)? in
            let words = canonical.split(whereSeparator: \.isWhitespace)
            guard (1...maximumWords).contains(words.count),
                  canonical.allSatisfy({ $0.isLetter || $0.isWhitespace }),
                  canonical.filter(\.isLetter).count >= minimumLetters else { return nil }
            return (canonical, words.count)
        }
        guard !usable.isEmpty else { return result }

        let ns = result as NSString
        let tokenList = tokens(in: result)
        var matches: [Match] = []
        var position = 0
        while position < tokenList.count {
            var best: Match?
            var ambiguous = false
            for (canonical, wordCount) in usable {
                for span in [wordCount, wordCount + 1] {
                    guard position + span <= tokenList.count else { continue }
                    let slice = Array(tokenList[position..<(position + span)])
                    let heard = slice.map(\.text).joined(separator: " ")
                    guard isPlainSpan(slice, in: ns),
                          !protected.contains(fold(heard)),
                          slice.allSatisfy({ token in
                              token.text.allSatisfy(\.isLetter)
                                  && token.text.count >= 2
                                  && !lexicon.isWord(token.text)
                          }) else { continue }
                    guard isCloseMiss(heard, of: canonical) else { continue }
                    let first = slice[0].range, last = slice[slice.count - 1].range
                    let range = NSRange(location: first.location, length: last.location + last.length - first.location)
                    let distance = distance(fold(heard).filter { !$0.isWhitespace }, fold(canonical).filter { !$0.isWhitespace })
                    if let current = best {
                        if distance < current.distance {
                            best = Match(range: range, canonical: canonical, distance: distance)
                            ambiguous = false
                        } else if distance == current.distance, current.canonical != canonical {
                            ambiguous = true
                        }
                    } else {
                        best = Match(range: range, canonical: canonical, distance: distance)
                    }
                    break
                }
            }
            if let best, !ambiguous {
                matches.append(best)
                let end = best.range.location + best.range.length
                while position < tokenList.count, tokenList[position].range.location < end { position += 1 }
            } else {
                position += 1
            }
        }
        guard !matches.isEmpty else { return result }
        let mutable = NSMutableString(string: result)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: match.canonical)
        }
        result = mutable as String
        return result
    }

    /// After cleanup: the model may lower or raise the case of one of the
    /// user's words it was given ("Maëlys" back as "maëlys"). When the
    /// rewrite has exactly as many case-insensitive matches of a word as its
    /// input, each takes the case it had in the input, in order. A word the
    /// input spelled as the everyday adjective keeps that spelling.
    static func restoringCase(of canonicals: [String], from input: String, in output: String) -> String {
        var result = output
        for canonical in canonicals where canonical.count >= 2 {
            guard let regex = try? NSRegularExpression(pattern: GlossaryVariantSafety.pattern(for: canonical)) else { continue }
            let inputNS = input as NSString
            let before = regex.matches(in: input, range: NSRange(location: 0, length: inputNS.length))
                .map { inputNS.substring(with: $0.range) }
            guard before.contains(canonical) else { continue }
            let outputNS = result as NSString
            let after = regex.matches(in: result, range: NSRange(location: 0, length: outputNS.length))
            guard after.count == before.count else { continue }
            let mutable = NSMutableString(string: result)
            for (match, original) in zip(after, before).reversed() where original == canonical {
                mutable.replaceCharacters(in: match.range, with: canonical)
            }
            result = mutable as String
        }
        return result
    }

    /// "kvellio" or "KVELLIO" for "Kvellio": written the user's way only when
    /// no word of the lower case form is an everyday word.
    static func applyingCaseOnlyFixes(to text: String, canonicals: [String], lexicon: WordLexicon) -> String {
        var result = text
        for canonical in canonicals {
            let words = tokens(in: canonical)
            guard canonical.count >= 3, !words.isEmpty,
                  words.allSatisfy({ !lexicon.isWord($0.text.lowercased()) && !lexicon.isWord($0.text) }) else { continue }
            let pattern = GlossaryVariantSafety.pattern(for: canonical)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            let found = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard found.contains(where: { ns.substring(with: $0.range) != canonical }) else { continue }
            let mutable = NSMutableString(string: result)
            for match in found.reversed() where ns.substring(with: match.range) != canonical {
                guard isPlainSpan([Token(text: "", range: match.range)], in: ns) else { continue }
                mutable.replaceCharacters(in: match.range, with: canonical)
            }
            result = mutable as String
        }
        return result
    }

    /// Words inside an address, a path or a file name are never touched, and
    /// a span only joins words separated by plain spaces.
    private static func isPlainSpan(_ slice: [Token], in text: NSString) -> Bool {
        guard let first = slice.first, let last = slice.last else { return false }
        for (left, right) in zip(slice, slice.dropFirst()) {
            let gapStart = left.range.location + left.range.length
            let gap = text.substring(with: NSRange(location: gapStart, length: right.range.location - gapStart))
            guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return false }
        }
        let start = first.range.location
        let end = last.range.location + last.range.length
        func character(at location: Int) -> Character {
            Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: location)))
        }
        let blockedBefore: Set<Character> = ["@", "/", "\\", "_", ".", ":", "#", "-"]
        let blockedAfter: Set<Character> = ["@", "/", "\\", "_", "-"]
        if start > 0, blockedBefore.contains(character(at: start - 1)) {
            return false
        }
        if end < text.length {
            let after = character(at: end)
            if blockedAfter.contains(after) { return false }
            if after == ".", end + 1 < text.length {
                let beyond = character(at: end + 1)
                if beyond.isLetter || beyond.isNumber { return false }
            }
        }
        return true
    }
}
