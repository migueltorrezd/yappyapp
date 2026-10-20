import Foundation

/// SNIPPETS: glossary and snippet sharing. Export writes only words and
/// snippets, never transcripts, stats or settings. Import reads a YappYapp
/// words file, a plain glossary.json or snippets.json array, or a glossary
/// CSV, then merges it into what is already saved. See docs/WORDS_FILES.md.
enum WordsFileFormat {
    static let identifier = "yappyapp-words"
    static let version = 1
    /// Larger files are refused before parsing.
    static let maximumBytes = 2_000_000
    /// Rows past this count are not read.
    static let maximumRows = 5_000
    static let csvHeader = ["write_it_as", "sounds_like", "notes"]
}

/// The exported JSON document. Its keys are the whole contract: nothing
/// else from the app support folder can ride along.
struct WordsExportBundle: Codable, Equatable {
    struct SharedSnippet: Codable, Equatable {
        var trigger: String
        var expansion: String
    }

    var format: String
    var version: Int
    var glossary: [GlossaryEntry]
    var snippets: [SharedSnippet]
}

enum WordsExportKind: String, CaseIterable {
    /// Words and snippets in one JSON file.
    case json
    /// Words only, as a spreadsheet-friendly CSV.
    case glossaryCSV

    var fileExtension: String {
        self == .json ? "json" : "csv"
    }

    var suggestedFileName: String {
        self == .json ? "YappYapp words.json" : "YappYapp words.csv"
    }
}

enum WordsExporter {
    static func bundle(glossary: [GlossaryEntry], snippets: [Snippet]) -> WordsExportBundle {
        WordsExportBundle(
            format: WordsFileFormat.identifier,
            version: WordsFileFormat.version,
            glossary: glossary.filter { !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            snippets: SnippetStore.cleaned(snippets).map {
                WordsExportBundle.SharedSnippet(trigger: $0.trigger, expansion: $0.expansion)
            }
        )
    }

    static func data(_ kind: WordsExportKind, glossary: [GlossaryEntry], snippets: [Snippet]) throws -> Data {
        switch kind {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(bundle(glossary: glossary, snippets: snippets))
        case .glossaryCSV:
            return Data(csv(glossary: glossary).utf8)
        }
    }

    /// RFC 4180 CSV with a header row. Sounds-like spellings share one cell,
    /// separated by commas, the same way the WORDS tab shows them.
    static func csv(glossary: [GlossaryEntry]) -> String {
        var lines = [WordsFileFormat.csvHeader.joined(separator: ",")]
        for entry in glossary where !entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cells = [entry.canonical, entry.variants.joined(separator: ", "), entry.notes ?? ""]
            lines.append(cells.map(CSVCodec.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

enum CSVCodec {
    /// Characters a spreadsheet would run as a formula at the start of a cell.
    static let formulaLeads: Set<Character> = ["=", "+", "-", "@"]

    static func escape(_ value: String) -> String {
        var cell = value
        // A cell that starts like a formula gets a leading apostrophe, so a
        // shared file never runs code in a spreadsheet. Import removes it.
        if let first = cell.first, formulaLeads.contains(first) {
            cell = "'" + cell
        }
        if cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || cell != cell.trimmingCharacters(in: .whitespaces) {
            return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cell
    }

    static func unescapeFormulaGuard(_ value: String) -> String {
        guard value.count >= 2, value.first == "'", let second = value.dropFirst().first, formulaLeads.contains(second) else {
            return value
        }
        return String(value.dropFirst())
    }

    /// Parses CSV rows, honoring quoted cells with commas, quotes and line
    /// breaks. Accepts LF or CRLF line ends.
    static func rows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = iterator.next()

        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        cell.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(character)
                }
                continue
            }
            switch character {
            case "\"" where cell.isEmpty:
                quoted = true
            case ",":
                row.append(cell)
                cell = ""
            case "\n", "\r\n", "\r":
                row.append(cell)
                rows.append(row)
                row = []
                cell = ""
            default:
                cell.append(character)
            }
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

/// What an import file contains, before it is merged.
struct WordsImportPayload: Equatable {
    var glossary: [GlossaryEntry] = []
    var snippets: [WordsExportBundle.SharedSnippet] = []
    /// Rows that could not be read at all.
    var unreadableRows = 0
}

enum WordsImportError: LocalizedError, Equatable {
    case tooLarge
    case notWordsFile
    case empty

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            return L10n.tr("That file is over 2 MB. A words file is much smaller.")
        case .notWordsFile:
            return L10n.tr("That file is not a YappYapp words file, a glossary or a CSV with words.")
        case .empty:
            return L10n.tr("That file has no words or snippets in it.")
        }
    }
}

enum WordsImportParser {
    static func parse(data: Data, fileExtension: String) throws -> WordsImportPayload {
        guard data.count <= WordsFileFormat.maximumBytes else { throw WordsImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw WordsImportError.notWordsFile }
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lead = body.trimmingCharacters(in: .whitespacesAndNewlines).first

        let payload: WordsImportPayload
        if fileExtension.lowercased() == "csv" || (lead != "{" && lead != "[") {
            payload = try parseCSV(body)
        } else {
            payload = try parseJSON(Data(body.utf8))
        }
        guard !payload.glossary.isEmpty || !payload.snippets.isEmpty else {
            throw WordsImportError.empty
        }
        return payload
    }

    static func parseJSON(_ data: Data) throws -> WordsImportPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw WordsImportError.notWordsFile
        }
        var payload = WordsImportPayload()
        var items: [Any] = []

        if let object = root as? [String: Any] {
            if let format = object["format"] as? String, format != WordsFileFormat.identifier {
                throw WordsImportError.notWordsFile
            }
            let glossary = object["glossary"] as? [Any] ?? []
            let snippets = object["snippets"] as? [Any] ?? []
            guard object["glossary"] != nil || object["snippets"] != nil else {
                throw WordsImportError.notWordsFile
            }
            items = glossary + snippets
        } else if let array = root as? [Any] {
            items = array
        } else {
            throw WordsImportError.notWordsFile
        }

        // Only the known fields of each row are read; anything else in the
        // file, such as a transcript someone pasted in, is ignored.
        for item in items.prefix(WordsFileFormat.maximumRows) {
            guard let row = item as? [String: Any] else {
                payload.unreadableRows += 1
                continue
            }
            if let canonical = row["canonical"] as? String {
                let variants = (row["variants"] as? [Any])?.compactMap { $0 as? String } ?? []
                let notes = row["notes"] as? String
                payload.glossary.append(GlossaryEntry(canonical: canonical, variants: variants, notes: notes))
            } else if let trigger = row["trigger"] as? String, let expansion = row["expansion"] as? String {
                payload.snippets.append(.init(trigger: trigger, expansion: expansion))
            } else {
                payload.unreadableRows += 1
            }
        }
        payload.unreadableRows += max(0, items.count - WordsFileFormat.maximumRows)
        return payload
    }

    static func parseCSV(_ text: String) throws -> WordsImportPayload {
        var rows = CSVCodec.rows(from: text)
        guard !rows.isEmpty else { throw WordsImportError.empty }
        let headerNames: Set<String> = ["write_it_as", "write it as", "canonical", "word", "spelling"]
        if let first = rows.first?.first, headerNames.contains(first.trimmingCharacters(in: .whitespaces).lowercased()) {
            rows.removeFirst()
        }

        var payload = WordsImportPayload()
        for row in rows.prefix(WordsFileFormat.maximumRows) {
            let canonical = CSVCodec.unescapeFormulaGuard(row[0].trimmingCharacters(in: .whitespaces))
            guard !canonical.isEmpty else {
                payload.unreadableRows += 1
                continue
            }
            let variantsCell = row.count > 1 ? CSVCodec.unescapeFormulaGuard(row[1]) : ""
            let variants = variantsCell
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let notesCell = row.count > 2 ? CSVCodec.unescapeFormulaGuard(row[2].trimmingCharacters(in: .whitespaces)) : ""
            payload.glossary.append(GlossaryEntry(canonical: canonical, variants: variants, notes: notesCell.isEmpty ? nil : notesCell))
        }
        payload.unreadableRows += max(0, rows.count - WordsFileFormat.maximumRows)
        return payload
    }
}

/// What to do when a shared snippet uses one of your phrases with other text.
enum SnippetConflictPolicy: Equatable {
    case keepMine
    case useImported
}

/// The merged result plus the counts the preview shows before anything is saved.
struct WordsImportPlan: Equatable {
    var glossary: [GlossaryEntry]
    var snippets: [Snippet]

    var newWords = 0
    /// Existing words that gain sounds-like spellings.
    var widenedWords = 0
    var sameWords = 0
    var newSnippets = 0
    var sameSnippets = 0
    /// Shared snippets whose phrase you already use with other text.
    var conflictingSnippets = 0
    /// Conflicts that took the shared text (policy `.useImported`).
    var replacedSnippets = 0
    /// Rows left out: unreadable, unsafe, or clashing with a word.
    var skippedRows = 0
    /// Sounds-like spellings left out because they would rewrite normal speech.
    var droppedSpellings = 0

    var hasChanges: Bool {
        newWords + widenedWords + newSnippets + replacedSnippets > 0
    }

    /// True when the conflict policy changes the result.
    var hasConflicts: Bool {
        conflictingSnippets > 0
    }
}

enum WordsImportMerger {
    static func plan(
        payload: WordsImportPayload,
        glossary existingGlossary: [GlossaryEntry],
        snippets existingSnippets: [Snippet],
        conflictPolicy: SnippetConflictPolicy = .keepMine
    ) -> WordsImportPlan {
        var plan = WordsImportPlan(glossary: existingGlossary, snippets: existingSnippets)
        plan.skippedRows = payload.unreadableRows

        // Words: same spelling (any case) merges its sounds-like spellings;
        // your own spelling, casing and notes always stay.
        for imported in payload.glossary {
            let canonical = imported.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, canonical.count <= SnippetTrigger.maximumLength else {
                plan.skippedRows += 1
                continue
            }
            var variants: [String] = []
            for variant in imported.variants {
                let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != canonical else { continue }
                guard GlossaryVariantSafety.isSafe(trimmed) else {
                    plan.droppedSpellings += 1
                    continue
                }
                variants.append(trimmed)
            }
            let notes = imported.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let index = plan.glossary.firstIndex(where: {
                $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(canonical) == .orderedSame
            }) {
                var entry = plan.glossary[index]
                var known = Set(entry.variants.map { $0.lowercased() })
                var added = false
                for variant in variants where known.insert(variant.lowercased()).inserted {
                    entry.variants.append(variant)
                    added = true
                }
                if (entry.notes ?? "").isEmpty, let notes, !notes.isEmpty {
                    entry.notes = notes
                }
                plan.glossary[index] = entry
                if added { plan.widenedWords += 1 } else { plan.sameWords += 1 }
            } else {
                var unique: [String] = []
                var known = Set<String>()
                for variant in variants where known.insert(variant.lowercased()).inserted {
                    unique.append(variant)
                }
                plan.glossary.append(GlossaryEntry(
                    canonical: canonical,
                    variants: unique,
                    notes: (notes?.isEmpty ?? true) ? nil : notes
                ))
                plan.newWords += 1
            }
        }

        // Snippets: same phrase with the same text is a duplicate; with other
        // text it is a conflict, settled by the policy. A phrase that is unsafe
        // or is already a word is skipped.
        for imported in payload.snippets {
            let trigger = imported.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = imported.expansion
            guard SnippetTrigger.safetyIssue(for: trigger) == nil,
                  !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  expansion.count <= SnippetTrigger.maximumExpansionLength,
                  SnippetDraftValidator.glossaryConflict(for: trigger, in: plan.glossary) == nil
            else {
                plan.skippedRows += 1
                continue
            }
            let key = SnippetTrigger.normalized(trigger)
            if let index = plan.snippets.firstIndex(where: { SnippetTrigger.normalized($0.trigger) == key }) {
                if plan.snippets[index].expansion == expansion {
                    plan.sameSnippets += 1
                } else {
                    plan.conflictingSnippets += 1
                    if conflictPolicy == .useImported {
                        plan.snippets[index].expansion = expansion
                        plan.replacedSnippets += 1
                    }
                }
            } else {
                plan.snippets.append(Snippet(trigger: trigger, expansion: expansion))
                plan.newSnippets += 1
            }
        }
        return plan
    }
}

/// Plain lines for the import preview. Zero counts are left out.
enum WordsImportPreview {
    static func lines(for plan: WordsImportPlan, policy: SnippetConflictPolicy) -> [String] {
        var lines: [String] = []
        func add(_ count: Int, _ one: String, _ many: String) {
            guard count > 0 else { return }
            lines.append("\(count) \(count == 1 ? one : many)")
        }
        add(plan.newWords, L10n.tr("NEW WORD"), L10n.tr("NEW WORDS"))
        add(plan.widenedWords, L10n.tr("WORD GETS NEW \"SOUNDS LIKE\""), L10n.tr("WORDS GET NEW \"SOUNDS LIKE\""))
        add(plan.newSnippets, L10n.tr("NEW SNIPPET"), L10n.tr("NEW SNIPPETS"))
        if plan.conflictingSnippets > 0 {
            // The same pair as the buttons: KEEP MINE or USE NEW.
            let choice = policy == .keepMine ? L10n.tr("KEEP MINE") : L10n.tr("USE NEW")
            add(
                plan.conflictingSnippets,
                L10n.tr("SNIPPET WITH OTHER TEXT · %@", choice),
                L10n.tr("SNIPPETS WITH OTHER TEXT · %@", choice)
            )
        }
        add(plan.sameWords + plan.sameSnippets, L10n.tr("ALREADY HERE"), L10n.tr("ALREADY HERE"))
        add(plan.droppedSpellings, L10n.tr("RISKY SPELLING SKIPPED"), L10n.tr("RISKY SPELLINGS SKIPPED"))
        add(plan.skippedRows, L10n.tr("ROW SKIPPED"), L10n.tr("ROWS SKIPPED"))
        if lines.isEmpty {
            lines.append(L10n.tr("NOTHING NEW"))
        }
        return lines
    }

    /// One sentence for the tab feedback after an import is applied.
    static func appliedMessage(for plan: WordsImportPlan) -> String {
        let words = plan.newWords + plan.widenedWords
        let snippets = plan.newSnippets
        return L10n.tr("Imported %@ and %@.", L10n.plural("%lld words", words), L10n.plural("%lld snippets", snippets))
    }
}
