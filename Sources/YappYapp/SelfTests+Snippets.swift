#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "snippets" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func snippetsTrackTests() {
        snippetsExpansionTests()
        snippetsGlossaryConflictTests()
        snippetsValidatorTests()
        snippetsStoreTests()
        snippetsExportTests()
        snippetsImportTests()
        snippetsMergeTests()
        snippetsRenderTests()
    }

    /// Scratch folder under the self-test base when one is set, so these
    /// tests never write outside it.
    private static func snippetsScratchURL(_ name: String) -> URL {
        let base = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("snippets-selftest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static let emailSnippet = Snippet(trigger: "my email address", expansion: "miguel@example.com")

    // MARK: - Expansion

    private static func snippetsExpansionTests() {
        let library = SnippetLibrary(snippets: [
            emailSnippet,
            Snippet(trigger: "my email", expansion: "SHORT"),
            Snippet(trigger: "sign off", expansion: "Best,\nMiguel"),
            Snippet(trigger: "price line", expansion: "$5 off, \\1 and $0 stay literal"),
            Snippet(trigger: "mon adresse mail", expansion: "miguel@example.fr"),
            Snippet(trigger: "über uns text", expansion: "UEBER"),
            Snippet(trigger: "我的邮箱", expansion: "cn@example.com")
        ])

        test("snippets.expandsInsideSentence") {
            expectEqual(
                library.expanding("Please write to my email address today."),
                "Please write to miguel@example.com today."
            )
        }

        test("snippets.caseAndSpacingInsensitive") {
            expectEqual(library.expanding("Send it to My  Email\tAddress, thanks"), "Send it to miguel@example.com, thanks")
        }

        test("snippets.wholeDictationDropsModelPeriod") {
            expectEqual(library.expanding("My email address."), "miguel@example.com")
            expectEqual(library.expanding("  sign off!  "), "Best,\nMiguel")
        }

        test("snippets.longestPhraseWins") {
            expectEqual(library.expanding("use my email address now"), "use miguel@example.com now")
            expectEqual(library.expanding("use my email now"), "use SHORT now")
        }

        test("snippets.wordBoundaries") {
            expectEqual(library.expanding("resign offline"), "resign offline", "phrase inside other words never fires")
            expectEqual(library.expanding("my emailing address"), "my emailing address")
            expectEqual(library.expanding("xmy email address"), "xmy email address")
            expectEqual(library.expanding("la-mon adresse mail"), "la-mon adresse mail", "hyphen counts as part of a word")
            expectEqual(library.expanding("c'mon adresse mail"), "c'mon adresse mail", "apostrophe counts as part of a word")
            expectEqual(library.expanding("(my email address)"), "(miguel@example.com)", "brackets are boundaries")
        }

        test("snippets.multilingual") {
            expectEqual(library.expanding("Voici mon adresse mail."), "Voici miguel@example.fr.")
            expectEqual(library.expanding("Lies den ÜBER UNS TEXT bitte"), "Lies den UEBER bitte", "case folds beyond ASCII")
            expectEqual(library.expanding("Lies den uber uns text bitte"), "Lies den uber uns text bitte", "accents are never folded")
            expectEqual(library.expanding("请发到我的邮箱谢谢"), "请发到cn@example.com谢谢", "spaceless scripts match inside a sentence")
        }

        test("snippets.expansionIsLiteralAndNotReExpanded") {
            expectEqual(library.expanding("the price line"), "the $5 off, \\1 and $0 stay literal")
            let chained = SnippetLibrary(snippets: [
                Snippet(trigger: "first phrase", expansion: "second phrase"),
                Snippet(trigger: "second phrase", expansion: "WRONG")
            ])
            expectEqual(chained.expanding("say first phrase now"), "say second phrase now", "inserted text is never expanded again")
        }

        test("snippets.repeatedPhraseExpandsEveryTime") {
            expectEqual(
                library.expanding("my email address and my email address"),
                "miguel@example.com and miguel@example.com"
            )
        }

        test("snippets.unsafeSavedPhrasesNeverFire") {
            let unsafe = SnippetLibrary(snippets: [
                Snippet(trigger: "signature", expansion: "ONE WORD"),
                Snippet(trigger: "and the", expansion: "COMMON"),
                Snippet(trigger: "valid phrase", expansion: "   ")
            ])
            let text = "signature and the valid phrase"
            expectEqual(unsafe.expanding(text), text)
        }

        test("snippets.emptyLibraryIsIdentity") {
            expectEqual(SnippetLibrary(snippets: []).expanding("my email address"), "my email address")
            expectEqual(library.expanding(""), "")
        }
    }

    // MARK: - Glossary interplay

    private static func snippetsGlossaryConflictTests() {
        let glossary = Glossary(entries: [
            GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil),
            GlossaryEntry(canonical: "YappYapp", variants: ["yap yap"], notes: nil)
        ])

        test("snippets.matchAfterGlossaryRewrite") {
            // The glossary runs first and turns "jenial" into "Genial"; the
            // phrase still matches.
            let library = SnippetLibrary(snippets: [Snippet(trigger: "jenial invoice footer", expansion: "FOOTER")])
            let corrected = glossary.applyingCorrections(to: "add the jenial invoice footer")
            expectEqual(corrected, "add the Genial invoice footer")
            expectEqual(library.expanding(corrected, glossary: glossary), "add the FOOTER")
            expectEqual(library.expanding(corrected), "add the Genial invoice footer", "without the glossary the raw phrase cannot match")
        }

        test("snippets.glossaryOutputIsNotRewritten") {
            let library = SnippetLibrary(snippets: [emailSnippet])
            expectEqual(library.expanding("YappYapp rocks", glossary: glossary), "YappYapp rocks")
        }

        test("snippets.validatorFlagsGlossaryClash") {
            let entries = glossary.entries
            expect(SnippetDraftValidator.issue(trigger: "Yap Yap", expansion: "x", glossary: entries)?.contains("already in your words") == true,
                   "phrase equal to a sounds-like spelling clashes")
            expect(SnippetDraftValidator.issue(trigger: "yappyapp", expansion: "x", glossary: entries) != nil,
                   "single word clashing with a spelling is refused")
            expectEqual(SnippetDraftValidator.issue(trigger: "yap yap launch note", expansion: "x", glossary: entries), nil,
                        "a longer phrase that contains a spelling is allowed")
            expectEqual(SnippetDraftValidator.glossaryConflict(for: "  YAP   YAP. ", in: entries), "YappYapp")
        }
    }

    // MARK: - Validation

    private static func snippetsValidatorTests() {
        test("snippets.validatorRules") {
            expectEqual(SnippetDraftValidator.issue(trigger: "", expansion: ""), nil, "blank row is ignored")
            expect(SnippetDraftValidator.issue(trigger: "", expansion: "text") == "Add the phrase you will say.", "missing phrase")
            expect(SnippetDraftValidator.issue(trigger: "my address", expansion: "  ") == "Add the text to write.", "missing text")
            expect(SnippetDraftValidator.issue(trigger: "address", expansion: "x")?.contains("two words") == true, "one word refused")
            expect(SnippetDraftValidator.issue(trigger: "and the", expansion: "x")?.contains("everyday") == true, "common words refused")
            expect(SnippetDraftValidator.issue(trigger: "et le", expansion: "x")?.contains("everyday") == true, "French common words refused")
            expect(SnippetDraftValidator.issue(trigger: "?? !!", expansion: "x") != nil, "punctuation only refused")
            expect(SnippetDraftValidator.issue(trigger: String(repeating: "ab ", count: 40), expansion: "x")?.contains("80") == true, "long phrase refused")
            expect(SnippetDraftValidator.issue(trigger: "my address", expansion: String(repeating: "x", count: 5_001)) != nil, "long text refused")
            expectEqual(SnippetDraftValidator.issue(trigger: "我的邮箱", expansion: "x"), nil, "spaceless phrase allowed")
            expect(SnippetDraftValidator.issue(trigger: "我", expansion: "x") != nil, "one spaceless character refused")
            expectEqual(SnippetDraftValidator.issue(trigger: "mon adresse", expansion: "x"), nil)
        }

        test("snippets.validatorDuplicates") {
            let issues = SnippetDraftValidator.issues(for: [
                (trigger: "my email address", expansion: "a"),
                (trigger: "My Email  Address.", expansion: "b"),
                (trigger: "", expansion: "")
            ])
            expectEqual(issues.count, 1)
            expect(issues[1]?.contains("already a snippet") == true, "second copy is marked, first stays clean")
        }
    }

    // MARK: - Storage

    private static func snippetsStoreTests() {
        test("snippets.storeRoundTripIsPrivate") {
            let url = snippetsScratchURL("snippets.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            expectEqual(try SnippetStore.load(from: url), [], "missing file loads empty")

            let saved = [
                Snippet(trigger: "  my email address ", expansion: "a@b.c"),
                Snippet(trigger: "", expansion: "dropped"),
                Snippet(trigger: "empty text", expansion: " "),
                Snippet(trigger: "sign off", expansion: "Best,\n  Miguel")
            ]
            try SnippetStore.save(saved, to: url)
            let loaded = try SnippetStore.load(from: url)
            expectEqual(loaded.map(\.trigger), ["my email address", "sign off"])
            expectEqual(loaded.last?.expansion, "Best,\n  Miguel", "stored text keeps its spacing")
            expectEqual(loaded.first?.id, saved.first?.id, "ids survive a save")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            expectEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        }

        test("snippets.decodeWithoutID") {
            let data = Data(#"[{"trigger":"my email address","expansion":"x"}]"#.utf8)
            let decoded = try JSONDecoder().decode([Snippet].self, from: data)
            expectEqual(decoded.first?.trigger, "my email address")
        }

        test("snippets.damagedFileIsKeptAsideNotFatal") {
            let url = snippetsScratchURL("snippets.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try PrivateFile.write(Data("{not json".utf8), to: url)
            let state = YappYappState()
            let library = SnippetPersistence.reload(into: state, from: url)
            expectEqual(library.count, 0)
            expect(!FileManager.default.fileExists(atPath: url.path), "damaged file moved aside")
            let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            expect(siblings.contains { $0.hasPrefix("snippets.json.unreadable-") }, "damaged bytes are kept")
            expect(state.tabFeedback[.words]?.isError == true, "WORDS tab shows the problem")
        }

        test("snippets.persistenceSaveUpdatesState") {
            let url = snippetsScratchURL("snippets.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = YappYappState()
            let library = SnippetPersistence.save([emailSnippet], state: state, to: url)
            expectEqual(library?.count, 1)
            expectEqual(state.snippets, [emailSnippet])
            expectEqual(SnippetPersistence.reload(into: state, from: url).snippets, [emailSnippet])
        }

        test("snippets.pathLivesInSupportFolder") {
            expectEqual(AppPaths.snippetsURL.deletingLastPathComponent().path, AppPaths.supportDirectory.path)
            expectEqual(AppPaths.snippetsURL.lastPathComponent, "snippets.json")
        }
    }

    // MARK: - Export

    private static func snippetsExportTests() {
        let glossary = [
            GlossaryEntry(canonical: "Genial", variants: ["jenial", "jen yal"], notes: "Studio, \"quoted\""),
            GlossaryEntry(canonical: "=SUM(A1)", variants: [], notes: nil),
            GlossaryEntry(canonical: "  ", variants: ["x"], notes: nil)
        ]

        test("snippets.exportJSONHasOnlyWordsAndSnippets") {
            let data = try WordsExporter.data(.json, glossary: glossary, snippets: [emailSnippet])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expectEqual(Set(object?.keys.map { $0 } ?? []), ["format", "version", "glossary", "snippets"])
            let text = String(decoding: data, as: UTF8.self)
            expect(!text.contains("transcript"), "export never carries transcripts")
            expect(!text.contains(emailSnippet.id.uuidString), "local ids stay local")
            let bundle = try JSONDecoder().decode(WordsExportBundle.self, from: data)
            expectEqual(bundle.format, WordsFileFormat.identifier)
            expectEqual(bundle.glossary.count, 2, "blank words are left out")
            expectEqual(bundle.snippets, [.init(trigger: "my email address", expansion: "miguel@example.com")])
        }

        test("snippets.exportCSVQuotesAndGuardsFormulas") {
            let csv = WordsExporter.csv(glossary: glossary)
            let lines = csv.components(separatedBy: "\r\n")
            expectEqual(lines[0], "write_it_as,sounds_like,notes")
            expectEqual(lines[1], #"Genial,"jenial, jen yal","Studio, ""quoted""""#)
            expectEqual(lines[2], "'=SUM(A1),,", "formula cells get an apostrophe")
        }

        test("snippets.csvRoundTrip") {
            let csv = WordsExporter.csv(glossary: glossary)
            let payload = try WordsImportParser.parse(data: Data(csv.utf8), fileExtension: "csv")
            expectEqual(payload.glossary, Array(glossary.prefix(2)))
        }

        test("snippets.jsonRoundTrip") {
            let data = try WordsExporter.data(.json, glossary: glossary, snippets: [emailSnippet])
            let payload = try WordsImportParser.parse(data: data, fileExtension: "json")
            expectEqual(payload.glossary.map(\.canonical), ["Genial", "=SUM(A1)"])
            expectEqual(payload.snippets.map(\.expansion), ["miguel@example.com"])
        }
    }

    // MARK: - Import parsing

    private static func snippetsImportTests() {
        test("snippets.importPlainGlossaryArray") {
            let data = Data(#"[{"canonical":"LUMEX","variants":["lou mex"]},{"trigger":"my email address","expansion":"x"},42]"#.utf8)
            let payload = try WordsImportParser.parse(data: data, fileExtension: "json")
            expectEqual(payload.glossary.first?.variants, ["lou mex"])
            expectEqual(payload.snippets.count, 1)
            expectEqual(payload.unreadableRows, 1)
        }

        test("snippets.importIgnoresExtraFields") {
            let data = Data(#"{"format":"yappyapp-words","version":1,"transcripts":["secret"],"glossary":[{"canonical":"A1","transcript":"secret"}]}"#.utf8)
            let payload = try WordsImportParser.parse(data: data, fileExtension: "json")
            expectEqual(payload.glossary, [GlossaryEntry(canonical: "A1", variants: [], notes: nil)])
        }

        test("snippets.importCSVVariants") {
            let csv = "\u{FEFF}Write it as,Sounds like\nGenial,\"jenial; jen yal\"\r\n,orphan\nLUMEX,lou mex|loo mecks\n"
            let payload = try WordsImportParser.parse(data: Data(csv.utf8), fileExtension: "CSV")
            expectEqual(payload.glossary.map(\.canonical), ["Genial", "LUMEX"])
            expectEqual(payload.glossary.first?.variants, ["jenial", "jen yal"])
            expectEqual(payload.glossary.last?.variants, ["lou mex", "loo mecks"])
            expectEqual(payload.unreadableRows, 1)
        }

        test("snippets.importRefusesBadFiles") {
            func failure(_ text: String, _ ext: String = "json") -> WordsImportError? {
                do {
                    _ = try WordsImportParser.parse(data: Data(text.utf8), fileExtension: ext)
                    return nil
                } catch {
                    return error as? WordsImportError
                }
            }
            expectEqual(failure(#"{"format":"other-app","glossary":[]}"#), .notWordsFile)
            expectEqual(failure(#"{"model":"x"}"#), .notWordsFile)
            expectEqual(failure("[]"), .empty)
            expectEqual(failure("", "csv"), .empty)
            expectEqual(failure(String(repeating: " ", count: WordsFileFormat.maximumBytes + 1)), .tooLarge)
            expectEqual(failure("{broken"), .notWordsFile)
        }
    }

    // MARK: - Merge rules

    private static func snippetsMergeTests() {
        let existingGlossary = [
            GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: "mine"),
            GlossaryEntry(canonical: "LUMEX", variants: ["lou mex"], notes: nil)
        ]
        let existingSnippets = [emailSnippet]
        let payload = WordsImportPayload(
            glossary: [
                GlossaryEntry(canonical: "genial", variants: ["Jenial", "jen yal", "the", "x"], notes: "theirs"),
                GlossaryEntry(canonical: "LUMEX", variants: ["lou mex"], notes: "theirs"),
                GlossaryEntry(canonical: "Vexlo", variants: ["vex low", "vex low"], notes: nil),
                GlossaryEntry(canonical: "  ", variants: [], notes: nil)
            ],
            snippets: [
                .init(trigger: "My Email Address", expansion: "miguel@example.com"),
                .init(trigger: "my email address", expansion: "other@example.com"),
                .init(trigger: "sign off", expansion: "Best"),
                .init(trigger: "vex low", expansion: "clash with a word"),
                .init(trigger: "signature", expansion: "one word")
            ],
            unreadableRows: 1
        )

        test("snippets.mergeKeepMine") {
            let plan = WordsImportMerger.plan(payload: payload, glossary: existingGlossary, snippets: existingSnippets)
            expectEqual(plan.newWords, 1)
            expectEqual(plan.widenedWords, 1)
            expectEqual(plan.sameWords, 1)
            expectEqual(plan.droppedSpellings, 2, "unsafe spellings are counted, not silently lost")
            expectEqual(plan.newSnippets, 1)
            expectEqual(plan.sameSnippets, 1)
            expectEqual(plan.conflictingSnippets, 1)
            expectEqual(plan.replacedSnippets, 0)
            expectEqual(plan.skippedRows, 4, "blank word, word clash, one-word phrase and the unreadable row")
            expect(plan.hasChanges && plan.hasConflicts, "plan reports changes and conflicts")

            let genial = plan.glossary.first { $0.canonical == "Genial" }
            expectEqual(genial?.variants, ["jenial", "jen yal"], "case-insensitive union keeps your spelling first")
            expectEqual(genial?.notes, "mine", "your notes stay")
            expectEqual(plan.glossary.first { $0.canonical == "LUMEX" }?.notes, "theirs", "empty notes are filled")
            expectEqual(plan.glossary.last, GlossaryEntry(canonical: "Vexlo", variants: ["vex low"], notes: nil))
            expectEqual(plan.snippets.first, emailSnippet, "your snippet text and id stay")
            expectEqual(plan.snippets.count, 2)
        }

        test("snippets.mergeUseTheirs") {
            let plan = WordsImportMerger.plan(
                payload: payload,
                glossary: existingGlossary,
                snippets: existingSnippets,
                conflictPolicy: .useImported
            )
            expectEqual(plan.snippets.first?.expansion, "other@example.com")
            expectEqual(plan.snippets.first?.id, emailSnippet.id, "a replaced snippet keeps its id")
            expectEqual(plan.replacedSnippets, 1)
        }

        test("snippets.mergeNothingNew") {
            let same = WordsImportPayload(glossary: existingGlossary, snippets: [.init(trigger: emailSnippet.trigger, expansion: emailSnippet.expansion)])
            let plan = WordsImportMerger.plan(payload: same, glossary: existingGlossary, snippets: existingSnippets)
            expect(!plan.hasChanges, "re-importing your own export changes nothing")
            expectEqual(plan.glossary, existingGlossary)
            expectEqual(WordsImportPreview.lines(for: plan, policy: .keepMine), ["3 ALREADY HERE"])
        }

        test("snippets.previewLines") {
            let plan = WordsImportMerger.plan(payload: payload, glossary: existingGlossary, snippets: existingSnippets)
            let lines = WordsImportPreview.lines(for: plan, policy: .keepMine)
            expectEqual(lines, [
                "1 NEW WORD",
                "1 WORD GETS NEW \"SOUNDS LIKE\"",
                "1 NEW SNIPPET",
                "1 SNIPPET WITH OTHER TEXT · KEEP MINE",
                "2 ALREADY HERE",
                "2 RISKY SPELLINGS SKIPPED",
                "4 ROWS SKIPPED"
            ])
            expect(WordsImportPreview.lines(for: plan, policy: .useImported).contains("1 SNIPPET WITH OTHER TEXT · USE NEW"), "policy changes the line, with the button words")
            expectEqual(WordsImportPreview.appliedMessage(for: plan), "Imported 2 words and 1 snippet.")
        }

        test("snippets.pendingImportLoadsFromDisk") {
            let url = snippetsScratchURL("team words.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let data = try WordsExporter.data(.json, glossary: existingGlossary, snippets: existingSnippets)
            try PrivateFile.write(data, to: url)
            let pending = try PendingWordsImport.load(from: url)
            expectEqual(pending.fileName, "team words.json")
            expect(!pending.plan(glossary: existingGlossary, snippets: existingSnippets).hasChanges, "own export is a no-op")
            expect(pending.plan(glossary: [], snippets: []).hasChanges, "fresh install gains everything")
        }
    }

    // MARK: - Rendering

    private static func snippetsRenderTests() {
        test("snippets.viewsRender") {
            let payload = WordsImportPayload(
                glossary: [GlossaryEntry(canonical: "Vexlo", variants: [], notes: nil)],
                snippets: [.init(trigger: "my email address", expansion: "other")]
            )
            let pending = PendingWordsImport(fileName: "team.json", payload: payload)
            let plan = pending.plan(glossary: [], snippets: [emailSnippet])
            let card = WordsImportPreviewCard(pending: pending, plan: plan, onPolicy: { _ in }, onCancel: {}, onApply: {})
                .background(Brutal.paper)
            expect(renderImage(card, width: 404, height: 300) != nil, "import preview renders")

            let row = BrutalSnippetRow(
                draft: .constant(SnippetDraft(trigger: "address", expansion: "x")),
                issue: SnippetDraftValidator.issue(trigger: "address", expansion: "x"),
                onDelete: {}
            )
            expect(renderImage(row, width: 404, height: 160) != nil, "snippet row renders with an issue")
            expect(renderImage(WordsExportChooser(snippetCount: 2, onExport: { _ in }, onCancel: {}), width: 404, height: 50) != nil,
                   "export chooser renders")

            let state = makeUIState()
            state.snippets = [emailSnippet]
            let popover = makeBrutalPopover(state)
            expect(renderImage(popover.wordsTab.background(Brutal.paper), width: 404, height: 480) != nil, "WORDS tab renders with the mode bar")
        }
    }
}
#endif
