import Foundation

// COMMANDS (missing feature 8): spoken edit commands. "New line", "new
// paragraph" and "scratch that" in EN, FR, ES (LatAm) and NL.
//
// A command only counts when it is a clause on its own: the transcript is cut
// at punctuation, and a clause whose words are exactly a command phrase is
// the command. "New line." and "Dear Ana, new line, thanks" trigger; "a new
// line of shoes" and "Can you delete that?" never do. The engines punctuate
// the pause around a command, so this keeps ordinary words untouched.
// Spoken punctuation ("period", "comma") is left out on purpose: those words
// are too common in normal speech to rewrite safely.

enum SpokenCommandKind: Equatable, Sendable {
    case newLine
    case newParagraph
    /// Removes the sentence before it, or the previous dictation when it
    /// opens the utterance.
    case scratchThat
}

struct SpokenCommandPhrase: Equatable, Sendable {
    let language: String
    let phrase: String
    let kind: SpokenCommandKind
}

enum SpokenCommandTable {
    /// Table-driven so a language is one block of rows. Phrases are matched
    /// without case or accents, so "nueva linea" and "efface ca" count too.
    static let phrases: [SpokenCommandPhrase] = [
        SpokenCommandPhrase(language: "en", phrase: "new line", kind: .newLine),
        SpokenCommandPhrase(language: "en", phrase: "newline", kind: .newLine),
        SpokenCommandPhrase(language: "en", phrase: "new paragraph", kind: .newParagraph),
        SpokenCommandPhrase(language: "en", phrase: "scratch that", kind: .scratchThat),
        SpokenCommandPhrase(language: "en", phrase: "delete that", kind: .scratchThat),

        SpokenCommandPhrase(language: "fr", phrase: "nouvelle ligne", kind: .newLine),
        SpokenCommandPhrase(language: "fr", phrase: "nouveau paragraphe", kind: .newParagraph),
        SpokenCommandPhrase(language: "fr", phrase: "efface ça", kind: .scratchThat),

        SpokenCommandPhrase(language: "es", phrase: "nueva línea", kind: .newLine),
        SpokenCommandPhrase(language: "es", phrase: "nuevo párrafo", kind: .newParagraph),
        SpokenCommandPhrase(language: "es", phrase: "borra eso", kind: .scratchThat),

        SpokenCommandPhrase(language: "nl", phrase: "nieuwe regel", kind: .newLine),
        SpokenCommandPhrase(language: "nl", phrase: "nieuwe alinea", kind: .newParagraph),
        SpokenCommandPhrase(language: "nl", phrase: "wis dat", kind: .scratchThat)
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let folded: [String: SpokenCommandKind] = {
        var map: [String: SpokenCommandKind] = [:]
        for row in phrases {
            map[fold(row.phrase)] = row.kind
        }
        return map
    }()

    /// The command a clause body is, if it is exactly one.
    static func command(forClauseBody body: String) -> SpokenCommandKind? {
        let stripped = body.trimmingCharacters(in: CharacterSet(charactersIn: "¡¿\"'«»“”‘’").union(.whitespaces))
        guard !stripped.isEmpty else { return nil }
        return folded[fold(stripped)]
    }
}

struct SpokenCommandResult: Equatable, Sendable {
    /// The transcript with every command applied. May be a bare newline.
    let text: String
    /// "Scratch that" opened the utterance: remove the previous dictation.
    let undoPrevious: Bool
    let appliedCommands: Int

    /// False when nothing is left to deliver (only "scratch that").
    var hasContent: Bool {
        text.contains { !$0.isWhitespace || $0.isNewline }
    }
}

enum SpokenCommands {
    /// Clause boundaries. Newlines count so a command can follow one.
    static let boundaryCharacters: Set<Character> = [".", "!", "?", ",", ";", ":", "…", "\n"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "\n"]

    struct Clause: Equatable {
        /// Leading whitespace plus words, without the closing punctuation.
        let body: String
        /// The punctuation run that closed the clause, possibly empty.
        let terminator: String
    }

    /// Splits text into clauses, losslessly: joining every body and
    /// terminator gives the input back.
    static func clauses(in text: String) -> [Clause] {
        var result: [Clause] = []
        var body = ""
        var terminator = ""
        for character in text {
            if boundaryCharacters.contains(character) {
                terminator.append(character)
            } else if !terminator.isEmpty {
                // Anything after the punctuation run opens the next clause.
                result.append(Clause(body: body, terminator: terminator))
                body = String(character)
                terminator = ""
            } else {
                body.append(character)
            }
        }
        if !body.isEmpty || !terminator.isEmpty {
            result.append(Clause(body: body, terminator: terminator))
        }
        return result
    }

    static func apply(to text: String) -> SpokenCommandResult {
        let parts = clauses(in: text)
        var output = ""
        var undoPrevious = false
        var applied = 0
        // After a line break or a scratch, the next words start a fresh line
        // or sentence: no leading space, first letter capitalized.
        var startFresh = false

        for clause in parts {
            // The body is trimmed before matching, so French "ligne !" counts.
            if let kind = SpokenCommandTable.command(forClauseBody: clause.body) {
                applied += 1
                switch kind {
                case .newLine, .newParagraph:
                    trimTrailingSpaces(&output)
                    output += kind == .newLine ? "\n" : "\n\n"
                    // The clause's own punctuation ("New line.") is dropped,
                    // but a newline inside it is kept.
                    output += clause.terminator.filter { $0 == "\n" }
                    startFresh = true
                case .scratchThat:
                    if output.allSatisfy(\.isWhitespace) && !output.contains(where: \.isNewline) {
                        undoPrevious = true
                        output = ""
                    } else {
                        removeLastSentence(&output)
                    }
                    startFresh = output.isEmpty || output.last?.isNewline == true
                    if !startFresh, !output.isEmpty {
                        // Keep the sentence before readable: "Hi. " + next.
                        trimTrailingSpaces(&output)
                    }
                }
                continue
            }

            var body = clause.body
            if startFresh {
                if output.isEmpty || output.last?.isNewline == true {
                    body = String(body.drop(while: { $0 == " " || $0 == "\t" }))
                }
                body = capitalizingFirstLetter(body)
                startFresh = body.allSatisfy(\.isWhitespace)
            }
            output += body + clause.terminator
        }

        trimTrailingSpaces(&output)
        if output.allSatisfy({ $0 == " " || $0 == "\t" }) {
            output = ""
        }
        return SpokenCommandResult(text: output, undoPrevious: undoPrevious, appliedCommands: applied)
    }

    /// Fast path for the pipeline: off, or no command in sight, returns the
    /// transcript untouched.
    static func process(_ text: String, enabled: Bool) -> SpokenCommandResult {
        guard enabled else {
            return SpokenCommandResult(text: text, undoPrevious: false, appliedCommands: 0)
        }
        let result = apply(to: text)
        guard result.appliedCommands > 0 else {
            return SpokenCommandResult(text: text, undoPrevious: false, appliedCommands: 0)
        }
        return result
    }

    private static func trimTrailingSpaces(_ text: inout String) {
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
    }

    /// Drops the last sentence: its closing punctuation, then everything back
    /// to the previous sentence end or line break.
    private static func removeLastSentence(_ text: inout String) {
        trimTrailingSpaces(&text)
        while let last = text.last, boundaryCharacters.contains(last), last != "\n" {
            text.removeLast()
        }
        if let index = text.lastIndex(where: { sentenceEnds.contains($0) }) {
            text = String(text[...index])
        } else {
            text = ""
        }
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let character = text[index]
        guard character.isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: character.uppercased())
    }
}

enum SpokenCommandCopy {
    static var settingsNote: String { L10n.tr("Say \"new line\", \"new paragraph\" or \"scratch that\" on its own. Works in French, Spanish and Dutch too.") }
    static var scratchedStatus: String { L10n.tr("Scratched. Nothing typed.") }
}
