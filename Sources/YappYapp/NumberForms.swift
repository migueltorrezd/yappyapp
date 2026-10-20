import Foundation

// NUMBERS: the deterministic number pass. Pure and conservative: when it is
// not sure a span is a number, it leaves the words as they are.
//
// DIGITS reads spoken number words (EN, FR, ES, NL) with a small parser:
// units, teens, tens, hundreds, thousands, millions, the "and/et/y/en"
// joiners, French "quatre-vingt-dix", Dutch compounds like "vijfentwintig",
// decimals ("point", "virgule", "coma", "komma") and percent. It converts
// numbers of 10 and up, decimals, years, and any number before a percent or
// a unit word. A lone one-to-nine word stays a word ("one of them", "un ami",
// "uno de ellos", "een huis"): whether it counts something is unknowable here.
// Two numbers side by side ("three thirty", "one two three") are left alone,
// except an English year ("nineteen eighty four").
//
// WORDS spells digits out with Foundation's spell-out formatter in the
// dictation language, and never touches years, times, versions, codes,
// phone-like runs, decimals with more than two places, numbers over 999,999,
// or digits inside or right after an identifier ("GPT-5", "M5", "iOS 26").
//
// Both leave URLs, emails, code-looking tokens, the user's glossary words and
// snippet phrases untouched.
enum NumberForms {
    /// Rewrites `text` in the plan's style. `protectedPhrases` are glossary
    /// canonicals and snippet phrases, never converted.
    /// `protectedRanges` are spans of `text` found elsewhere (snippet phrases).
    static func apply(
        _ text: String,
        plan: NumberPlan,
        protectedPhrases: [String] = [],
        protectedRanges extra: [Range<String.Index>] = []
    ) -> String {
        guard plan.style != .asSpoken, let language = plan.language, !text.isEmpty,
              text.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        // Only phrases that could hold a number need a search.
        let phrases = protectedPhrases.filter { mightHoldNumber($0, language: language) }
        let protected = protectedRanges(in: text, phrases: phrases) + extra
        switch plan.style {
        case .asSpoken: return text
        case .digits: return toDigits(text, language: language, protected: protected, aggressive: false)
        case .words: return toWords(text, language: language, protected: protected)
        }
    }

    /// Every number as plain digits, for comparing two texts by value: the
    /// cleanup guard uses it so "twenty five" and "25" count as the same word.
    static func canonical(_ text: String, language: NumberLanguage) -> String {
        let digits = toDigits(text, language: language, protected: [], aggressive: true)
        return digits.replacingOccurrences(
            of: "(?<=\\d)[,.\u{00A0}\u{202F}](?=\\d{3}(?!\\d))",
            with: "",
            options: .regularExpression
        )
    }

    /// Whether a phrase has a digit or a number word in it.
    static func mightHoldNumber(_ phrase: String, language: NumberLanguage) -> Bool {
        tokenize(phrase).contains { token in
            switch token.kind {
            case .number: true
            case .word: atoms(forWord: token.text, language: language) != nil
            default: false
            }
        }
    }

    // MARK: - Tokens

    struct Token: Equatable {
        enum Kind: Equatable { case word, number, space, newline, other }
        let kind: Kind
        let range: Range<String.Index>
        let text: Substring
    }

    static let numberSeparators: Set<Character> = [".", ",", "\u{00A0}", "\u{202F}"]
    static let wordJoiners: Set<Character> = ["-", "'", "\u{2019}"]

    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Words (letters with inner hyphens or apostrophes), digit runs (with
    /// inner separators), spaces, line breaks, and single other characters.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        func next(_ i: String.Index) -> Character? {
            let after = text.index(after: i)
            return after < text.endIndex ? text[after] : nil
        }
        while index < text.endIndex {
            let character = text[index]
            var end = text.index(after: index)
            let kind: Token.Kind
            if character.isLetter {
                kind = .word
                while end < text.endIndex {
                    let current = text[end]
                    if current.isLetter {
                        end = text.index(after: end)
                    } else if wordJoiners.contains(current), let following = next(end), following.isLetter {
                        end = text.index(after: end)
                    } else {
                        break
                    }
                }
            } else if isDigit(character) {
                kind = .number
                while end < text.endIndex {
                    let current = text[end]
                    if isDigit(current) {
                        end = text.index(after: end)
                    } else if numberSeparators.contains(current), let following = next(end), isDigit(following) {
                        end = text.index(after: end)
                    } else {
                        break
                    }
                }
            } else if character.isNewline {
                kind = .newline
            } else if character.isWhitespace {
                kind = .space
                while end < text.endIndex, text[end].isWhitespace, !text[end].isNewline {
                    end = text.index(after: end)
                }
            } else {
                kind = .other
            }
            tokens.append(Token(kind: kind, range: index..<end, text: text[index..<end]))
            index = end
        }
        return tokens
    }

    // MARK: - Protected spans

    private static let chunkLeading = CharacterSet(charactersIn: "([{\"'\u{201C}\u{2018}\u{00AB}<")
    private static let chunkTrailing = CharacterSet(charactersIn: ".,;:!?)]}\"'\u{201D}\u{2019}\u{00BB}\u{2026}>")
    private static let codeCharacters: Set<Character> = ["_", "/", "\\", "`", "=", "{", "}", "<", ">", "|", "~", "^", "[", "]", "@", "#", "$", "*", "&", "+"]

    /// Spans the pass never rewrites: URLs and emails, code-looking or
    /// alphanumeric tokens, times like "3:30", and the given phrases.
    static func protectedRanges(in text: String, phrases: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []

        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lower = index
            var upper = end
            while lower < upper, text[lower].unicodeScalars.allSatisfy({ chunkLeading.contains($0) }) {
                lower = text.index(after: lower)
            }
            while lower < upper {
                let last = text.index(before: upper)
                guard text[last].unicodeScalars.allSatisfy({ chunkTrailing.contains($0) }) else { break }
                upper = last
            }
            if lower < upper, looksLikeCode(text[lower..<upper]) {
                ranges.append(lower..<upper)
            }
            index = end
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { ranges.append(range) }
            }
        }

        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trimmed) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { ranges.append(range) }
            }
        }
        return ranges
    }

    static func looksLikeCode(_ chunk: Substring) -> Bool {
        if chunk.contains(where: { codeCharacters.contains($0) }) { return true }
        let characters = Array(chunk)
        let hasLetter = characters.contains(where: \.isLetter)
        let hasDigit = characters.contains(where: isDigit)
        if hasLetter && hasDigit { return true }
        for position in characters.indices.dropFirst().dropLast() {
            let before = characters[position - 1]
            let after = characters[position + 1]
            switch characters[position] {
            case ":" where !before.isWhitespace && !after.isWhitespace:
                return true
            case "." where before.isLetter && after.isLetter:
                return true
            default:
                break
            }
        }
        // camelCase: a capital right after a lowercase letter.
        for position in characters.indices.dropFirst() where characters[position].isUppercase && characters[position - 1].isLowercase {
            return true
        }
        return false
    }

    static func overlaps(_ range: Range<String.Index>, _ protected: [Range<String.Index>]) -> Bool {
        protected.contains { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }
    }

    // MARK: - Words to digits

    /// One atom of a run, with the words it came from.
    struct RunAtom: Equatable {
        var atom: NumberAtom
        var firstWord: Int
        var lastWord: Int
        /// First atom of `firstWord`.
        var startsWord: Bool
        /// Last atom of `lastWord`.
        var endsWord: Bool
    }

    /// The atoms one written word stands for, or nil when it is not a number
    /// word. Hyphenated words must be number words in every part.
    static func atoms(forWord word: Substring, language: NumberLanguage) -> [NumberAtom]? {
        let folded = NumberLexicon.fold(String(word))
        let table = NumberLexicon.table(language)
        if let atom = table[folded] { return [atom] }
        if folded.contains("-") {
            var result: [NumberAtom] = []
            for part in folded.split(separator: "-", omittingEmptySubsequences: false) {
                if let atom = table[String(part)] {
                    result.append(atom)
                } else if language == .nl, let pieces = dutchAtoms(String(part)) {
                    result += pieces
                } else {
                    return nil
                }
            }
            return result
        }
        if language == .nl { return dutchAtoms(folded) }
        return nil
    }

    private static func dutchAtoms(_ folded: String) -> [NumberAtom]? {
        guard let pieces = NumberLexicon.dutchPieces(folded), pieces.count >= 2 else { return nil }
        var atoms = pieces.compactMap { NumberLexicon.dutch[$0] }
        // "vijf" + "en" + "twintig" is 25.
        var merged: [NumberAtom] = []
        var position = 0
        while position < atoms.count {
            if position + 2 < atoms.count,
               case .digit(let unit) = atoms[position], unit > 0,
               atoms[position + 1] == .joiner,
               case .tens(let tens) = atoms[position + 2] {
                merged.append(.tensUnit(tens + unit))
                position += 3
            } else {
                merged.append(atoms[position])
                position += 1
            }
        }
        atoms = merged
        // A joiner left inside one word is not a number ("tienen").
        guard !atoms.contains(.joiner) else { return nil }
        return atoms
    }

    private static func isValueAtom(_ atom: NumberAtom) -> Bool {
        switch atom {
        case .joiner, .point: false
        default: true
        }
    }

    /// Converts number words to digits. `aggressive` (the guard's canonical
    /// form) converts every number, ignores protection and never groups.
    static func toDigits(_ text: String, language: NumberLanguage, protected: [Range<String.Index>], aggressive: Bool) -> String {
        let tokens = tokenize(text)
        var replacements: [(range: Range<String.Index>, text: String)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.kind == .number {
                // "25 percent" becomes "25%".
                if let percentEnd = percentPhraseEnd(after: index, in: tokens, language: language) {
                    let range = token.range.lowerBound..<tokens[percentEnd].range.upperBound
                    if aggressive || !overlaps(range, protected) {
                        replacements.append((range, String(token.text) + (aggressive ? "%" : NumberLexicon.percentSign(language))))
                    }
                    index = percentEnd + 1
                } else {
                    index += 1
                }
                continue
            }
            guard token.kind == .word, let words = runWords(from: index, in: tokens, language: language) else {
                index += 1
                continue
            }
            let outcome = convertRun(words, tokens: tokens, language: language, protected: protected, aggressive: aggressive)
            replacements += outcome.replacements
            index = outcome.lastToken + 1
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    /// Token indices of consecutive number words starting at `start`,
    /// one space apart. Joiners and decimal words only count between numbers.
    static func runWords(from start: Int, in tokens: [Token], language: NumberLanguage) -> [(token: Int, atoms: [NumberAtom])]? {
        var words: [(token: Int, atoms: [NumberAtom])] = []
        var index = start
        while index < tokens.count, tokens[index].kind == .word {
            let text = tokens[index].text
            var atoms = atoms(forWord: text, language: language)
            // English "a hundred", "a thousand".
            if atoms == nil, language == .en, NumberLexicon.fold(String(text)) == "a",
               index + 2 < tokens.count, tokens[index + 1].kind == .space, tokens[index + 2].kind == .word,
               let following = self.atoms(forWord: tokens[index + 2].text, language: language)?.first {
                switch following {
                case .hundred(plural: false), .scale(1_000, plural: false): atoms = [.digit(1)]
                default: break
                }
            }
            guard let atoms else { break }
            words.append((index, atoms))
            guard index + 2 < tokens.count, tokens[index + 1].kind == .space, tokens[index + 2].kind == .word else { break }
            index += 2
        }
        // A run starts and ends on a number.
        while let last = words.last, !last.atoms.contains(where: isValueAtom) { words.removeLast() }
        guard let first = words.first, first.atoms.first.map(isValueAtom) == true else { return nil }
        return words
    }

    private struct Parsed {
        var value: Int
        var start: Int
        var end: Int
        var fraction: String?
        var separator: Character?
        /// "two million": the scale word is kept, the multiplier is written.
        var keptScale: Int?
    }

    private enum Item {
        case number(Parsed)
        case breaker(Int)
    }

    private static func convertRun(
        _ words: [(token: Int, atoms: [NumberAtom])],
        tokens: [Token],
        language: NumberLanguage,
        protected: [Range<String.Index>],
        aggressive: Bool
    ) -> (replacements: [(range: Range<String.Index>, text: String)], lastToken: Int) {
        let lastWordToken = words[words.count - 1].token
        let trailingPercent = percentPhraseEnd(after: lastWordToken, in: tokens, language: language)
        let lastToken = trailingPercent ?? lastWordToken

        var atoms: [RunAtom] = []
        for (wordIndex, word) in words.enumerated() {
            for (position, atom) in word.atoms.enumerated() {
                atoms.append(RunAtom(
                    atom: atom, firstWord: wordIndex, lastWord: wordIndex,
                    startsWord: position == 0, endsWord: position == word.atoms.count - 1
                ))
            }
        }
        if language == .fr { atoms = mergeFrench(atoms) }

        let parser = Parser(atoms: atoms.map(\.atom), language: language)
        var items: [Item] = []
        var position = 0
        while position < atoms.count {
            if let parsed = parser.parse(at: position) {
                guard atoms[parsed.start].startsWord, atoms[parsed.end - 1].endsWord else {
                    // A number that splits a word: not sure, leave the run.
                    return ([], lastToken)
                }
                items.append(.number(parsed))
                position = parsed.end
            } else {
                guard atoms[position].startsWord, atoms[position].endsWord else { return ([], lastToken) }
                items.append(.breaker(position))
                position += 1
            }
        }

        // Numbers between breakers. Two side by side are ambiguous, unless
        // they are an English year.
        var segments: [[Parsed]] = [[]]
        for item in items {
            switch item {
            case .number(let parsed): segments[segments.count - 1].append(parsed)
            case .breaker: segments.append([])
            }
        }
        var candidates: [Parsed] = []
        for segment in segments where !segment.isEmpty {
            if segment.count == 1 {
                candidates.append(segment[0])
            } else if segment.count == 2, language == .en, let year = englishYear(segment[0], segment[1], atoms: atoms) {
                candidates.append(year)
            } else if aggressive {
                candidates += segment
            }
        }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        for candidate in candidates {
            let firstToken = words[atoms[candidate.start].firstWord].token
            let endToken = words[atoms[candidate.end - 1].lastWord].token
            let isLast = endToken == lastWordToken
            let percentEnd = isLast ? trailingPercent : nil
            let hasUnit = isLast && percentEnd == nil && followedByUnit(endToken, in: tokens, language: language)

            let convert = aggressive
                || candidate.fraction != nil
                || candidate.value >= 10
                || percentEnd != nil
                || (hasUnit && candidate.value >= 2)
            guard convert else { continue }

            let range = tokens[firstToken].range.lowerBound..<tokens[percentEnd ?? endToken].range.upperBound
            guard aggressive || !overlaps(range, protected) else { continue }

            var written = digits(for: candidate, language: language, plain: aggressive)
            if candidate.keptScale != nil {
                written += " " + tokens[endToken].text
            }
            if percentEnd != nil {
                written += aggressive ? "%" : NumberLexicon.percentSign(language)
            }
            replacements.append((range, written))
        }
        return (replacements, lastToken)
    }

    /// French "quatre-vingt" is 80, "dix-sept" is 17.
    private static func mergeFrench(_ atoms: [RunAtom]) -> [RunAtom] {
        var result: [RunAtom] = []
        var position = 0
        while position < atoms.count {
            if position + 1 < atoms.count {
                let pair = (atoms[position].atom, atoms[position + 1].atom)
                var merged: NumberAtom?
                if case .digit(4) = pair.0, case .tens(20) = pair.1 { merged = .tens(80) }
                if case .teen(10) = pair.0, case .digit(let unit) = pair.1, unit >= 7 { merged = .teen(10 + unit) }
                if let merged {
                    result.append(RunAtom(
                        atom: merged,
                        firstWord: atoms[position].firstWord,
                        lastWord: atoms[position + 1].lastWord,
                        startsWord: atoms[position].startsWord,
                        endsWord: atoms[position + 1].endsWord
                    ))
                    position += 2
                    continue
                }
            }
            result.append(atoms[position])
            position += 1
        }
        return result
    }

    /// "nineteen eighty four", "twenty twenty five": 11-20 then 10-99.
    private static func englishYear(_ first: Parsed, _ second: Parsed, atoms: [RunAtom]) -> Parsed? {
        guard first.fraction == nil, second.fraction == nil, first.keptScale == nil, second.keptScale == nil,
              first.end - first.start == 1, (11...20).contains(first.value),
              (10...99).contains(second.value), second.end - second.start <= 2 else { return nil }
        if case .tens(let tens) = atoms[first.start].atom, tens != 20 { return nil }
        return Parsed(value: first.value * 100 + second.value, start: first.start, end: second.end)
    }

    private static func digits(for parsed: Parsed, language: NumberLanguage, plain: Bool) -> String {
        let integer = parsed.keptScale.map { parsed.value / $0 } ?? parsed.value
        var grouping = NumberLexicon.groupingSeparator(language)
        if let separator = parsed.separator, grouping == String(separator) {
            grouping = separator == "," ? "." : ","
        }
        var written = String(integer)
        if !plain, parsed.keptScale == nil, integer >= 10_000 {
            written = grouped(written, separator: grouping)
        }
        if let fraction = parsed.fraction, let separator = parsed.separator {
            written += String(separator) + fraction
        }
        return written
    }

    static func grouped(_ digits: String, separator: String) -> String {
        var groups: [String] = []
        var remaining = Substring(digits)
        while remaining.count > 3 {
            groups.insert(String(remaining.suffix(3)), at: 0)
            remaining = remaining.dropLast(3)
        }
        groups.insert(String(remaining), at: 0)
        return groups.joined(separator: separator)
    }

    /// The last token of a percent phrase right after `token`, if any.
    static func percentPhraseEnd(after token: Int, in tokens: [Token], language: NumberLanguage) -> Int? {
        for phrase in NumberLexicon.percentPhrases(language) {
            var index = token
            var matched = true
            for word in phrase {
                guard index + 2 < tokens.count, tokens[index + 1].kind == .space, tokens[index + 2].kind == .word,
                      NumberLexicon.fold(String(tokens[index + 2].text)) == word else {
                    matched = false
                    break
                }
                index += 2
            }
            if matched { return index }
        }
        return nil
    }

    static func followedByUnit(_ token: Int, in tokens: [Token], language: NumberLanguage) -> Bool {
        guard token + 2 < tokens.count, tokens[token + 1].kind == .space, tokens[token + 2].kind == .word else { return false }
        return NumberLexicon.units(language).contains(NumberLexicon.fold(String(tokens[token + 2].text)))
    }

    // MARK: - Parser

    /// Reads one number from a list of atoms: groups below 1,000 joined by
    /// scales, then an optional decimal part.
    private struct Parser {
        let atoms: [NumberAtom]
        let language: NumberLanguage

        func parse(at start: Int) -> Parsed? {
            guard let number = parseNumber(at: start) else { return nil }
            var parsed = Parsed(value: number.value, start: start, end: number.next, keptScale: number.keptScale)
            if number.keptScale == nil, number.next + 1 < atoms.count,
               case .point(let separator) = atoms[number.next],
               let fraction = parseFraction(at: number.next + 1) {
                parsed.fraction = fraction.digits
                parsed.separator = separator
                parsed.end = fraction.next
                // "three point five million"
                if parsed.end < atoms.count, number.value < 1_000,
                   case .scale(let scale, _) = atoms[parsed.end], scale >= 1_000_000 {
                    parsed.value = number.value * scale
                    parsed.keptScale = scale
                    parsed.end += 1
                }
            }
            return parsed
        }

        private func parseNumber(at start: Int) -> (value: Int, next: Int, keptScale: Int?)? {
            var total = 0
            var position = start
            var lastScale = Int.max
            var any = false
            var keptScale: Int?
            while position < atoms.count {
                let group = parseGroup(at: position)
                let afterGroup = group?.next ?? position
                if afterGroup < atoms.count, case .scale(let scale, let plural) = atoms[afterGroup], scale < lastScale {
                    if group == nil {
                        // A bare "millions" or "thanks a million" is no number.
                        guard !plural, scale < 1_000_000, !any else { break }
                    }
                    let multiplier = group?.value ?? 1
                    guard multiplier > 0 else { break }
                    total += multiplier * scale
                    lastScale = scale
                    position = afterGroup + 1
                    any = true
                    keptScale = (scale >= 1_000_000 && multiplier < 1_000) ? scale : nil
                    // "one thousand and five", "duizend en vijf"
                    if [.en, .nl].contains(language), position + 1 < atoms.count, atoms[position] == .joiner,
                       let tail = parseGroup(at: position + 1), tail.value < scale {
                        position += 1
                    }
                    continue
                }
                if let group {
                    total += group.value
                    position = group.next
                    any = true
                    keptScale = nil
                }
                break
            }
            guard any else { return nil }
            if let kept = keptScale, total % kept != 0 { keptScale = nil }
            return (total, position, keptScale)
        }

        /// A value below 1,000.
        private func parseGroup(at start: Int) -> (value: Int, next: Int)? {
            guard start < atoms.count else { return nil }
            var position = start
            var value = 0
            var any = false
            var hasHundreds = false

            switch atoms[position] {
            case .hundreds(let hundreds):
                value = hundreds
                position += 1
                hasHundreds = true
            case .hundred(plural: false):
                value = 100
                position += 1
                hasHundreds = true
            case .digit(let unit) where unit >= 1 && isHundred(at: position + 1):
                value = unit * 100
                position += 2
                hasHundreds = true
            case .teen(let teen) where (language == .en || language == .nl) && isHundred(at: position + 1):
                // "nineteen hundred", "negentienhonderd"
                value = teen * 100
                position += 2
                hasHundreds = true
            default:
                break
            }
            any = hasHundreds

            if hasHundreds, [.en, .nl].contains(language), position + 1 < atoms.count, atoms[position] == .joiner,
               startsBelowHundred(atoms[position + 1]) {
                position += 1
            }

            guard position < atoms.count else { return any ? (value, position) : nil }
            switch atoms[position] {
            case .tensUnit(let tensUnit):
                value += tensUnit
                position += 1
                any = true
            case .tens(let tens):
                value += tens
                position += 1
                any = true
                guard position < atoms.count else { break }
                switch atoms[position] {
                case .digit(let unit) where unit >= 1 && (language == .en || language == .fr):
                    value += unit
                    position += 1
                case .teen(let teen) where language == .fr && (tens == 60 || tens == 80):
                    // "soixante-dix", "quatre-vingt-dix-neuf"
                    value += teen
                    position += 1
                case .joiner where position + 1 < atoms.count:
                    switch (language, atoms[position + 1]) {
                    case (.es, .digit(let unit)) where unit >= 1:
                        value += unit
                        position += 2
                    case (.fr, .digit(1)) where (20...60).contains(tens):
                        value += 1
                        position += 2
                    case (.fr, .teen(11)) where tens == 60:
                        value += 11
                        position += 2
                    default:
                        break
                    }
                default:
                    break
                }
            case .teen(let teen):
                value += teen
                position += 1
                any = true
            case .digit(let unit) where language == .nl && unit >= 1 && position + 2 < atoms.count
                && atoms[position + 1] == .joiner && isTens(at: position + 2):
                // "vijf en twintig", written apart.
                if case .tens(let tens) = atoms[position + 2] { value += tens + unit }
                position += 3
                any = true
            case .digit(let unit) where !(hasHundreds && unit == 0):
                value += unit
                position += 1
                any = true
            default:
                break
            }
            return any ? (value, position) : nil
        }

        private func isHundred(at position: Int) -> Bool {
            guard position < atoms.count, case .hundred = atoms[position] else { return false }
            return true
        }

        private func isTens(at position: Int) -> Bool {
            guard position < atoms.count, case .tens = atoms[position] else { return false }
            return true
        }

        private func startsBelowHundred(_ atom: NumberAtom) -> Bool {
            switch atom {
            case .digit(let unit): unit >= 1
            case .teen, .tens, .tensUnit: true
            default: false
            }
        }

        /// Digits after the decimal word: one word per digit, or one number
        /// below 100 ("trois virgule vingt-cinq").
        private func parseFraction(at start: Int) -> (digits: String, next: Int)? {
            guard start < atoms.count else { return nil }
            if case .digit = atoms[start] {
                var digits = ""
                var position = start
                while position < atoms.count, case .digit(let unit) = atoms[position] {
                    digits += String(unit)
                    position += 1
                }
                return (digits, position)
            }
            guard let group = parseGroup(at: start), group.value < 100 else { return nil }
            return (String(group.value), group.next)
        }
    }

    // MARK: - Digits to words

    static func toWords(_ text: String, language: NumberLanguage, protected: [Range<String.Index>]) -> String {
        let tokens = tokenize(text)
        let formatter = NumberFormatter()
        formatter.locale = NumberLexicon.locale(language)
        formatter.numberStyle = .spellOut
        func spell(_ value: Int) -> String {
            (formatter.string(from: NSNumber(value: value)) ?? String(value))
                .replacingOccurrences(of: "\u{00AD}", with: "")
        }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        for (index, token) in tokens.enumerated() where token.kind == .number {
            guard !overlaps(token.range, protected),
                  isStandalone(index, in: tokens, text: text),
                  let reading = readDigits(token.text, language: language) else { continue }

            var words = spell(reading.integer)
            if let fraction = reading.fraction, let separator = reading.separator {
                let fractionWords: String
                if language != .en, fraction.count == 2, !fraction.hasPrefix("0"), let value = Int(fraction) {
                    fractionWords = spell(value)
                } else {
                    fractionWords = fraction.compactMap(\.wholeNumberValue).map(spell).joined(separator: " ")
                }
                words += " " + NumberLexicon.decimalWord(language, separator: separator) + " " + fractionWords
            }

            var range = token.range
            if let percent = percentSign(after: token.range.upperBound, in: text) {
                range = token.range.lowerBound..<percent
                words += " " + NumberLexicon.percentWord(language)
            }
            if startsSentence(token.range.lowerBound, in: text), let first = words.first {
                words = first.uppercased() + words.dropFirst()
            }
            replacements.append((range, words))
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    struct DigitReading: Equatable {
        var integer: Int
        var fraction: String?
        var separator: Character?
    }

    static let maxSpelledValue = 999_999

    /// Reads a digit token in the language's conventions. nil for anything
    /// WORDS must leave alone: years, codes with a leading zero, long runs,
    /// more than two decimals, values over 999,999, unclear separators.
    static func readDigits(_ token: Substring, language: NumberLanguage) -> DigitReading? {
        var segments: [String] = [""]
        var separators: [Character] = []
        for character in token {
            if isDigit(character) {
                segments[segments.count - 1].append(character)
            } else {
                separators.append(character)
                segments.append("")
            }
        }

        var fraction: String?
        var decimalSeparator: Character?
        if let last = separators.last, NumberLexicon.readDecimalSeparators(language).contains(last),
           let tail = segments.last, (1...2).contains(tail.count),
           separators.dropLast().allSatisfy({ $0 != last }) {
            fraction = tail
            decimalSeparator = last
            separators.removeLast()
            segments.removeLast()
        }
        if let fraction, fraction.count > 2 { return nil }

        let integerDigits: String
        if separators.isEmpty {
            integerDigits = segments[0]
        } else {
            let grouping = NumberLexicon.readGroupingSeparators(language)
            guard Set(separators).count == 1, let separator = separators.first, grouping.contains(separator),
                  (1...3).contains(segments[0].count), segments.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            integerDigits = segments.joined()
        }

        guard !integerDigits.isEmpty, integerDigits.count <= 6 else { return nil }
        // "007", "0612": a code, not an amount.
        if integerDigits.count > 1, integerDigits.hasPrefix("0") { return nil }
        guard let integer = Int(integerDigits), integer <= maxSpelledValue else { return nil }
        // A bare four-digit year stays digits.
        if separators.isEmpty, fraction == nil, integerDigits.count == 4, (1000...2199).contains(integer) { return nil }
        return DigitReading(integer: integer, fraction: fraction, separator: decimalSeparator)
    }

    private static let identifierPrefixes: Set<Character> = ["_", "-", "/", "\\", ":", ".", ",", "#", "@", "$", "\u{20AC}", "\u{00A3}", "\u{00A5}", "+", "&", "*", "^", "~", "=", "<", ">", "|", "`", "'", "\u{2019}"]
    private static let identifierSuffixes: Set<Character> = ["_", "-", "/", "\\", ":", "@", "$", "\u{20AC}", "\u{00A3}", "\u{00A5}", "+", "&", "*", "^", "~", "=", "<", ">", "|", "`", "\u{00B0}", "'", "\u{2019}", "#"]

    private static let currencySymbols: Set<Character> = ["$", "\u{20AC}", "\u{00A3}", "\u{00A5}"]

    /// Whether a digit token is a plain amount: not glued to letters or
    /// symbols, not a list marker, not part of a phone-like run, and not
    /// right after an identifier like "iOS" or "version".
    private static func isStandalone(_ index: Int, in tokens: [Token], text: String) -> Bool {
        let token = tokens[index]
        if token.range.lowerBound > text.startIndex {
            let before = text[text.index(before: token.range.lowerBound)]
            if before.isLetter || isDigit(before) || identifierPrefixes.contains(before) { return false }
        }
        if token.range.upperBound < text.endIndex {
            let after = text[token.range.upperBound]
            if after.isLetter || isDigit(after) || identifierSuffixes.contains(after) { return false }
            // "3.x", "2,a": glued to what follows.
            if after == "." || after == "," {
                let next = text.index(after: token.range.upperBound)
                if next < text.endIndex, text[next].isLetter || isDigit(text[next]) { return false }
            }
            // "1." or "2)" opening a line: a list marker.
            if (after == "." || after == ")"), opensLine(token.range.lowerBound, in: text) { return false }
        }
        // Another digit run one space or dash away: a phone number or code.
        if index >= 2, tokens[index - 2].kind == .number, [.space, .other].contains(tokens[index - 1].kind), tokens[index - 1].text.count == 1 {
            return false
        }
        if index + 2 < tokens.count, tokens[index + 2].kind == .number, [.space, .other].contains(tokens[index + 1].kind), tokens[index + 1].text.count == 1 {
            return false
        }
        // "5 €": an amount with a symbol stays in digits.
        if index + 2 < tokens.count, tokens[index + 1].kind == .space, tokens[index + 2].kind == .other,
           let symbol = tokens[index + 2].text.first, currencySymbols.contains(symbol) {
            return false
        }
        // "iOS 26", "GPT 5", "version 2".
        if index >= 2, tokens[index - 1].kind == .space, tokens[index - 2].kind == .word {
            let word = tokens[index - 2].text
            if isIdentifierWord(word) || NumberLexicon.identifierWords.contains(NumberLexicon.fold(String(word))) { return false }
        }
        return true
    }

    /// "iOS", "macOS", "GPT", "USB": a capital after the first letter.
    static func isIdentifierWord(_ word: Substring) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return word.first?.isUppercase == true && word.count == 1 }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    private static func opensLine(_ position: String.Index, in text: String) -> Bool {
        var index = position
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isNewline { return true }
            guard character.isWhitespace else { return false }
            index = previous
        }
        return true
    }

    private static func startsSentence(_ position: String.Index, in text: String) -> Bool {
        var index = position
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isNewline || ".!?\u{2026}".contains(character) { return true }
            guard character.isWhitespace else { return false }
            index = previous
        }
        return true
    }

    /// The end of a "%" right after a number, with at most one space between.
    private static func percentSign(after position: String.Index, in text: String) -> String.Index? {
        var index = position
        if index < text.endIndex, [" ", "\u{00A0}", "\u{202F}"].contains(text[index]) {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "%" else { return nil }
        return text.index(after: index)
    }
}
