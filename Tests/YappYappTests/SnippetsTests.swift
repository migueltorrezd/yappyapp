import Foundation
import Testing
@testable import YappYapp

@Test
func snippetExpandsOnlyOnWholePhrase() {
    let library = SnippetLibrary(snippets: [Snippet(trigger: "my email address", expansion: "me@example.com")])
    #expect(library.expanding("write my email address here") == "write me@example.com here")
    #expect(library.expanding("write my email addresses here") == "write my email addresses here")
    #expect(library.expanding("My Email Address.") == "me@example.com")
}

@Test
func snippetRunsAfterGlossarySpelling() {
    let glossary = Glossary(entries: [GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)])
    let library = SnippetLibrary(snippets: [Snippet(trigger: "jenial footer text", expansion: "FOOTER")])
    let corrected = glossary.applyingCorrections(to: "the jenial footer text")
    #expect(library.expanding(corrected, glossary: glossary) == "the FOOTER")
}

@Test
func snippetTriggerSafety() {
    #expect(SnippetTrigger.safetyIssue(for: "address") != nil)
    #expect(SnippetTrigger.safetyIssue(for: "de la") != nil)
    #expect(SnippetTrigger.safetyIssue(for: "mi correo") == nil)
    #expect(SnippetTrigger.safetyIssue(for: "我的邮箱") == nil)
}

@Test
func importMergeKeepsYoursByDefault() {
    let mine = Snippet(trigger: "sign off", expansion: "Mine")
    let payload = WordsImportPayload(snippets: [.init(trigger: "Sign Off", expansion: "Theirs")])
    let keep = WordsImportMerger.plan(payload: payload, glossary: [], snippets: [mine])
    #expect(keep.snippets == [mine])
    #expect(keep.conflictingSnippets == 1)
    #expect(!keep.hasChanges)
    let take = WordsImportMerger.plan(payload: payload, glossary: [], snippets: [mine], conflictPolicy: .useImported)
    #expect(take.snippets.first?.expansion == "Theirs")
    #expect(take.hasChanges)
}

@Test
func csvParserHandlesQuotedLineBreaks() {
    let rows = CSVCodec.rows(from: "a,\"b, c\",\"line\nbreak\"\r\nd,\"say \"\"hi\"\"\"\n")
    #expect(rows == [["a", "b, c", "line\nbreak"], ["d", "say \"hi\""]])
}
