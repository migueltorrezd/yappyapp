import Foundation

/// Deterministic removal of spoken filler words after transcription.
/// The list is conservative: only sounds that are never real words in
/// English, French, Spanish, or Dutch. Words like "ben" (FR), "este" (ES),
/// or "eh" are intentionally excluded because they carry meaning.
enum FillerWords {
    // FIX fillerNewline: trailing match uses [ \t]* (not \s*) so a line-final
    // filler ("So um\nNext line") does not swallow the following newline and
    // merge two lines. Same-line joins still collapse cleanly via the [ \t]{2,}
    // tidy pass below.
    // YA-47: hyphens and apostrophes count as word characters on both sides,
    // so "Uh-oh" and "uh-huh" stay intact. The trailing group captures the
    // punctuation that belonged to the filler ("um,", "uh...", "euh.") so the
    // sentence around it can be repaired instead of left as "think.." or "Bon,.".
    private static let pattern = #"(?i)(?<![\p{L}\p{N}'’\-])(um+|uh+|uhm|erm|ehm|euh+|heu|hmm+|mmm+|ähm|äh)(?![\p{L}\p{N}'’\-])([ \t]*[,;:.!?…]+)?[ \t]*"#

    private static let terminalMarks: Set<Character> = [".", "!", "?", "…"]

    static func removing(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        var removedAny = false

        // Work from the end so earlier ranges stay valid after each edit.
        for match in matches.reversed() {
            guard let fillerRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            // YA-47: an all-caps "UM" or "UH" is an acronym, not a hesitation.
            let filler = result[fillerRange]
            if filler.count >= 2, filler == filler.uppercased(), filler != filler.lowercased() {
                continue
            }

            let trailing = Range(match.range(at: 2), in: result).map { String(result[$0]) } ?? ""
            let trailingMarks = trailing.filter { !$0.isWhitespace }
            let endsSentence = trailingMarks.contains { terminalMarks.contains($0) }

            // Look back across spaces to see what precedes the filler.
            var precedingIndex = fillerRange.lowerBound
            while precedingIndex > result.startIndex {
                let previous = result.index(before: precedingIndex)
                guard result[previous] == " " || result[previous] == "\t" else { break }
                precedingIndex = previous
            }
            let precedingCharacter: Character? = precedingIndex > result.startIndex
                ? result[result.index(before: precedingIndex)]
                : nil
            // An ellipsis is a pause inside the sentence, not its end.
            let followsEllipsis = precedingCharacter == "…"
                || result[..<precedingIndex].hasSuffix("..")
            let atSentenceStart = precedingCharacter == nil
                || precedingCharacter == "\n"
                || (terminalMarks.contains(precedingCharacter!) && !followsEllipsis)

            removedAny = true

            if atSentenceStart {
                // "Um, so we start" -> "So we start". The filler's own
                // punctuation has nothing to attach to, so it goes with it.
                let offset = result.distance(from: result.startIndex, to: fullRange.lowerBound)
                result.replaceSubrange(fullRange, with: "")
                capitalizeWord(in: &result, atOffset: offset)
            } else if endsSentence {
                // "I think um." -> "I think." and "Bon, euh." -> "Bon.": the
                // sentence end survives, a dangling comma before it does not.
                var start = precedingIndex
                if start > result.startIndex {
                    let previous = result.index(before: start)
                    if result[previous] == "," || result[previous] == ";" {
                        start = previous
                    }
                }
                let mark = trailingMarks.contains("…") || trailingMarks.hasPrefix("...")
                    ? "..."
                    : String(trailingMarks.first { terminalMarks.contains($0) } ?? ".")
                let hadSpaceAfter = result[fillerRange.upperBound..<fullRange.upperBound].last.map { $0 == " " || $0 == "\t" } ?? false
                let atEnd = fullRange.upperBound == result.endIndex
                let replacement = mark + (hadSpaceAfter && !atEnd ? " " : "")
                let offset = result.distance(from: result.startIndex, to: start)
                result.replaceSubrange(start..<fullRange.upperBound, with: replacement)
                // An ellipsis is a pause, not a sentence end.
                if mark != "..." {
                    capitalizeWord(in: &result, atOffset: offset + replacement.count)
                }
            } else {
                // Mid-sentence: "I think, um, that works" -> "I think, that works".
                result.replaceSubrange(fullRange, with: "")
            }
        }

        // FIX fillerNewline: preserve paragraph/line structure. Collapse only runs of
        // spaces/tabs (never newlines), then tidy spaces left hugging a newline without
        // deleting the newline itself. The old \s{2,} pass flattened multi-line dictation
        // into a single line whenever filler removal was on.
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]+([,.!?;:])"#, with: "$1", options: .regularExpression)
        if removedAny {
            // YA-47: a comma left in front of a sentence end ("Bon,.") or a doubled
            // separator collapses to the stronger mark. A real ellipsis is kept.
            // Only text a filler was removed from is touched.
            result = result.replacingOccurrences(of: #"[,;]+([.!?…])"#, with: "$1", options: .regularExpression)
            result = result.replacingOccurrences(of: #"([,;])[,;]+"#, with: "$1", options: .regularExpression)
            result = result.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)
            // A dictation that now opens on punctuation drops it: ". So" -> "So".
            result = result.replacingOccurrences(of: #"^[ \t]*[,;:.!?…]+[ \t]*"#, with: "", options: .regularExpression)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the dictation was nothing but fillers, keep the original text
        // rather than producing an empty or punctuation-only transcript.
        let hasContent = result.contains { $0.isLetter || $0.isNumber }
        return hasContent ? result : text
    }

    /// Uppercases the first letter at `offset` (skipping spaces and newlines)
    /// only when it is lowercase. Used where a removed filler opened a sentence.
    private static func capitalizeWord(in text: inout String, atOffset offset: Int) {
        guard offset <= text.count else { return }
        var cursor = text.index(text.startIndex, offsetBy: offset)
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor].isLowercase else { return }
        let upper = String(text[cursor]).uppercased()
        text.replaceSubrange(cursor...cursor, with: upper)
    }
}
