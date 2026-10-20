#if DEBUG
import Foundation

// LEARN-FROM-FIXES and WORDS-NEAR-MISS: the release-critical rules, pinned in
// the self-test too. The full cases live in LearnFromFixesTests.swift.
extension SelfTests {
    static func learnFromFixesTests() {
        let lexicon = StaticWordLexicon(["send", "it", "to", "today", "genial", "general", "qué", "es", "una", "idea", "muy"])

        test("words.learnFromFixes.rules") {
            let learned = AutoLearn.proposals(
                inserted: "send it to jenial today", edited: "send it to Genial today",
                entries: [], neverLearn: [], lexicon: lexicon
            )
            expectEqual(learned.map(\.canonical), ["Genial"])
            expect(AutoLearn.proposals(
                inserted: "send it to genial today", edited: "send it to Genial today",
                entries: [], neverLearn: [], lexicon: lexicon
            ).isEmpty, "a case-only fix is never learned")
            expect(AutoLearn.proposals(
                inserted: "send it to jenial today", edited: "send it to Genial today",
                entries: [], neverLearn: [AutoLearn.blockKey(canonical: "Genial")], lexicon: lexicon
            ).isEmpty, "a deleted word is never learned again")
            expect(AutoLearn.looksLikeAddressNumberOrFile("jane@genial.com"), "addresses are never learned")
            expect(AppConfig.defaultConfig.learnFromFixes, "on by default")
        }

        test("words.nearMiss.everydayWordsStay") {
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "Genial", variants: [], notes: nil)], lexicon: lexicon)
            expectEqual(glossary.applyingCorrections(to: "send it to jenial today"), "send it to Genial today")
            expectEqual(glossary.applyingCorrections(to: "¡Qué genial! Es una idea muy genial."), "¡Qué genial! Es una idea muy genial.")
        }
    }
}
#endif
