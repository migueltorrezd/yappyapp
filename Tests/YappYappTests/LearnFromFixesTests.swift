import Foundation
import Testing
@testable import YappYapp

// LEARN-FROM-FIXES and WORDS-NEAR-MISS: the word diff, the learn rules, the
// word list edits, the field region, the near-miss pre-pass and the cleanup
// guard's excuse for a near-miss swap. A fixed word list stands in for the
// macOS dictionaries so every case is deterministic.

private let lexicon = StaticWordLexicon([
    // English
    "a", "about", "and", "ask", "at", "buy", "by", "call", "cluster", "contract", "deck", "deployed", "dot", "five",
    "friday", "general", "genial", "go", "i", "is", "it", "loved", "meeting", "monday", "nice", "on", "open",
    "please", "say", "send", "so", "team", "thanks", "that", "the", "they", "to", "today", "um", "want", "we",
    "with", "yesterday", "com", "mail", "jane", "me", "read", "reed", "this", "was", "really", "ok", "use", "café", "cafe",
    // Spanish and French
    "qué", "que", "es", "muy", "idea", "la", "una", "c'est", "vraiment", "génial", "le", "projet", "envoyé", "facture",
    "à", "hier", "soir", "j'ai", "mañana", "hablo", "con", "sobre", "el", "proyecto", "et"
])

private func learn(
    _ inserted: String,
    _ edited: String,
    entries: [GlossaryEntry] = [],
    neverLearn: Set<String> = []
) -> [AutoLearn.Proposal] {
    AutoLearn.proposals(inserted: inserted, edited: edited, entries: entries, neverLearn: neverLearn, lexicon: lexicon)
}

private func rejection(_ heard: [String], _ fixed: [String], startsSentence: Bool = false, entries: [GlossaryEntry] = [], neverLearn: Set<String> = []) -> AutoLearn.Rejection? {
    let substitution = AutoLearn.Substitution(heard: heard, fixed: fixed, fixedStartsSentence: startsSentence)
    switch AutoLearn.evaluate(substitution, entries: entries, neverLearn: neverLearn, lexicon: lexicon) {
    case .success: return nil
    case .failure(let error): return error.reason
    }
}

// MARK: - Diff

@Test
func learnDiffFindsOneSubstitution() throws {
    let diff = try #require(AutoLearn.diff(inserted: "send the contract to jenial today", edited: "send the contract to Genial today"))
    #expect(diff.substitutions == [AutoLearn.Substitution(heard: ["jenial"], fixed: ["Genial"], fixedStartsSentence: false)])
    #expect(diff.changedWords == 1)
    #expect(diff.dictatedWords == 6)
}

@Test
func learnDiffSeparatesInsertionsDeletionsAndPunctuation() throws {
    // "um" deleted, punctuation added, "please" typed after the dictation.
    let diff = try #require(AutoLearn.diff(inserted: "um so send it to jenial", edited: "So, send it to Genial. Please"))
    #expect(diff.substitutions.contains(AutoLearn.Substitution(heard: ["jenial"], fixed: ["Genial"], fixedStartsSentence: false)))
    // Punctuation alone is never a change.
    let same = try #require(AutoLearn.diff(inserted: "send it to Genial", edited: "send it, to Genial!"))
    #expect(same.substitutions.isEmpty)
    #expect(same.changedWords == 0)
}

@Test
func learnDiffMarksSentenceStarts() throws {
    let diff = try #require(AutoLearn.diff(inserted: "it shipped. general is happy", edited: "it shipped. Genial is happy"))
    #expect(diff.substitutions.first?.fixedStartsSentence == true)
    let opening = try #require(AutoLearn.diff(inserted: "jenial is happy", edited: "Genial is happy"))
    #expect(opening.substitutions.first?.fixedStartsSentence == true)
}

@Test
func learnDiffSplitsCJKCharacters() {
    let words = AutoLearn.words("我们用jenial做演示")
    #expect(words.map(\.text) == ["我", "们", "用", "jenial", "做", "演", "示"])
}

// MARK: - Proposals

@Test
func learnsACapitalizedNameTheEngineCouldNotSpell() {
    let proposals = learn("send the contract to jenial today", "send the contract to Genial today")
    #expect(proposals == [AutoLearn.Proposal(heard: "jenial", fixed: "Genial", change: .addWord(canonical: "Genial", variant: "jenial"))])
}

@Test
func learnsANameAroundOtherEdits() {
    let proposals = learn("um so send it to jenial", "So, send it to Genial. Please")
    #expect(proposals.map(\.canonical) == ["Genial"])
}

@Test
func learnsSeveralFixesInOneDictation() {
    let proposals = learn("meeting with saorsa and kvelio on monday", "meeting with Saoirse and Kvellio on monday")
    #expect(proposals.map(\.canonical) == ["Saoirse", "Kvellio"])
    #expect(proposals.map(\.change) == [
        .addWord(canonical: "Saoirse", variant: "saorsa"),
        .addWord(canonical: "Kvellio", variant: "kvelio")
    ])
}

@Test
func learnsAShortPhraseAndATermWithDigits() {
    let phrase = learn("call sersha nwachuku today", "call Saoirse Nwachukwu today")
    #expect(phrase.map(\.canonical) == ["Saoirse Nwachukwu"])
    let term = learn("we use gpt five today", "we use GPT-5 today")
    #expect(term.map(\.canonical) == ["GPT-5"])
    // "gpt five" is not all everyday words, so it becomes the sounds-like.
    #expect(term.first?.change == .addWord(canonical: "GPT-5", variant: "gpt five"))
    let mixed = learn("install yappy app on this mac", "install YappYapp on this mac")
    #expect(mixed == [AutoLearn.Proposal(heard: "yappy app", fixed: "YappYapp", change: .addWord(canonical: "YappYapp", variant: "yappy app"))])
}

@Test
func neverLearnsACaseOrPunctuationOnlyFix() {
    #expect(learn("talk to genial today", "talk to Genial today").isEmpty)
    #expect(rejection(["genial"], ["Genial"]) == .caseOrPunctuationOnly)
    #expect(rejection(["kvellio"], ["Kvellio!"]) == .caseOrPunctuationOnly)
}

@Test
func neverLearnsEverydayWords() {
    // Lower case fixes are spelling, not names.
    #expect(learn("i want to by it", "i want to buy it").isEmpty)
    #expect(rejection(["by"], ["buy"]) == .notANameOrTerm)
    // A capitalized everyday word replacing an everyday word is a rewrite.
    #expect(rejection(["friday"], ["Monday"]) == .dictionaryWord)
    #expect(rejection(["general"], ["Genial"]) == .dictionaryWord)
    // At a sentence start a capital proves nothing.
    #expect(rejection(["jenial"], ["Genial"], startsSentence: true) == .dictionaryWord)
    // Accents on a lower case word are a spelling fix, not a name.
    #expect(rejection(["cafe"], ["café"]) == .notANameOrTerm)
}

@Test
func neverLearnsAddressesNumbersFilesOrEmoji() {
    #expect(rejection(["genial", "dot", "com"], ["genial.com"]) == .addressNumberOrFile)
    #expect(rejection(["jane", "at", "kvellio"], ["jane@Kvellio.io"]) == .addressNumberOrFile)
    #expect(rejection(["kvellio"], ["https://Kvellio.io"]) == .addressNumberOrFile)
    #expect(rejection(["five"], ["5"]) == .addressNumberOrFile)
    #expect(rejection(["reed", "me"], ["README.md"]) == .addressNumberOrFile)
    #expect(rejection(["kvellio"], ["Kv🚀ellio"]) == .addressNumberOrFile)
    #expect(learn("open the reed me file", "open the README.md file").isEmpty)
}

@Test
func neverLearnsALongEditOrARewrite() {
    #expect(rejection(["a", "b", "c", "d"], ["Kvellio"]) == .tooLong)
    #expect(rejection(["kvelio"], ["Kvellio", "Big", "Corp", "Inc"]) == .tooLong)
    #expect(learn("send the deck to the team today", "Kvellio Saoirse Monday Zoltrix deck today").isEmpty)
}

@Test
func neverLearnsAnUnrelatedWord() {
    #expect(rejection(["team"], ["Kvellio"]) == .notSimilar)
}

@Test
func neverRelearnsADeletedWord() {
    let blocked: Set<String> = [AutoLearn.blockKey(canonical: "Genial")]
    #expect(learn("send it to jenial today", "send it to Genial today", neverLearn: blocked).isEmpty)
    #expect(rejection(["jenial"], ["Genial"], neverLearn: blocked) == .neverLearn)
    // A deleted sounds-like pair stays deleted too.
    let existing = [GlossaryEntry(canonical: "Genial", variants: [], notes: nil)]
    let pair: Set<String> = [AutoLearn.pairKey(heard: "jenial", canonical: "Genial")]
    #expect(rejection(["jenial"], ["Genial"], entries: existing, neverLearn: pair) == .alreadyKnown)
}

@Test
func addsTheMisheardSpellingToAnExistingWord() {
    let existing = [GlossaryEntry(canonical: "Genial", variants: ["jen yal"], notes: nil)]
    #expect(learn("send it to jenial today", "send it to Genial today", entries: existing)
        == [AutoLearn.Proposal(heard: "jenial", fixed: "Genial", change: .addVariant(canonical: "Genial", variant: "jenial"))])
    // Nothing new to add: already a sounds-like, or an everyday word.
    let known = [GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)]
    #expect(learn("send it to jenial today", "send it to Genial today", entries: known).isEmpty)
    // A different spelling of a saved word is the user's call, not ours.
    #expect(rejection(["kvelio"], ["KVELLIO"], entries: [GlossaryEntry(canonical: "Kvellio", variants: [], notes: nil)]) == .alreadyKnown)
}

@Test
func learnsAnEverydayHeardWordWithoutASoundsLike() {
    // "saw" is an everyday word: swapping it would rewrite sentences, so
    // only the spelling is learned.
    let proposals = AutoLearn.proposals(
        inserted: "ask saw about it",
        edited: "ask Saoirse about it",
        entries: [],
        neverLearn: [],
        lexicon: StaticWordLexicon(["ask", "saw", "about", "it"])
    )
    #expect(proposals.first?.change == .addWord(canonical: "Saoirse", variant: nil))
}

@Test
func learnsInCJKTextAndWithAccents() {
    #expect(learn("我们用 jenial 做演示", "我们用 Genial 做演示").map(\.canonical) == ["Genial"])
    #expect(learn("我们用jenial做演示", "我们用Genial做演示").map(\.canonical) == ["Genial"])
    // A changed Chinese character has no capitals: never a learn.
    #expect(learn("我们用张三做演示", "我们用章三做演示").isEmpty)
    // An accent added to a name is learned, with the plain spelling as its
    // sounds-like.
    #expect(learn("j'ai envoyé la facture à maelys hier soir", "j'ai envoyé la facture à Maëlys hier soir")
        == [AutoLearn.Proposal(heard: "maelys", fixed: "Maëlys", change: .addWord(canonical: "Maëlys", variant: "maelys"))])
    #expect(learn("mañana hablo con itsiar sobre el proyecto", "mañana hablo con Itziar sobre el proyecto").map(\.canonical) == ["Itziar"])
}

@Test
func learnsAtMostThreeWordsPerDictation() {
    let proposals = learn("kvelio saorsa zoltrik pyxelik tjarda ok", "Kvellio Saoirse Zoltrix Pyxeliq Tjaarda ok")
    #expect(proposals.isEmpty, "five of six words changed is a rewrite")
    let fewer = learn(
        "kvelio and saorsa and zoltrik and pyxelik and the team and the deck",
        "Kvellio and Saoirse and Zoltrix and Pyxeliq and the team and the deck"
    )
    #expect(fewer.count == AutoLearn.maxLearnsPerDictation)
}

// MARK: - Word list edits

@Test
func learnedWordsAreMarkedAndUndoable() {
    let start = [GlossaryEntry(canonical: "YappYapp", variants: [], notes: nil)]
    let proposal = AutoLearn.Proposal(heard: "jenial", fixed: "Genial", change: .addWord(canonical: "Genial", variant: "jenial"))
    let learned = AutoLearn.applying(proposal, to: start)
    #expect(learned.first == GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil, learned: true))
    #expect(learned.count == 2)
    #expect(AutoLearn.applying(proposal, to: learned) == learned, "never added twice")

    let undone = AutoLearn.undoing(proposal, from: learned)
    #expect(undone.entries == start)
    #expect(undone.blockKey == AutoLearn.blockKey(canonical: "Genial"))

    let variant = AutoLearn.Proposal(heard: "yapy app", fixed: "YappYapp", change: .addVariant(canonical: "YappYapp", variant: "yapy app"))
    let withVariant = AutoLearn.applying(variant, to: start)
    #expect(withVariant.first?.variants == ["yapy app"])
    #expect(withVariant.first?.isLearned == false, "the user's own word stays theirs")
    let variantUndone = AutoLearn.undoing(variant, from: withVariant)
    #expect(variantUndone.entries == start)
    #expect(variantUndone.blockKey == AutoLearn.pairKey(heard: "yapy app", canonical: "YappYapp"))
}

@Test
func deletingALearnedWordInWordsBlocksIt() {
    let old = [
        GlossaryEntry(canonical: "Genial", variants: [], notes: nil, learned: true),
        GlossaryEntry(canonical: "YappYapp", variants: [], notes: nil)
    ]
    #expect(AutoLearn.deletedLearnedWords(old: old, new: [old[1]]) == ["genial"])
    #expect(AutoLearn.deletedLearnedWords(old: old, new: [old[0]]).isEmpty, "the user's own words are not blocked")
    #expect(AutoLearn.deletedLearnedWords(old: old, new: old).isEmpty)
}

@Test
func neverLearnListIsCappedAndPersistsKeysOnly() throws {
    var list: [String] = []
    list = NeverLearnList.adding(["genial", "genial", ""], to: list)
    #expect(list == ["genial"])
    let many = (0..<600).map { "w\($0)" }
    let capped = NeverLearnList.adding(many, to: list)
    #expect(capped.count == NeverLearnList.limit)
    #expect(capped.last == "w599")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yappyapp-test-never-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try NeverLearnList.save(["genial"], to: url)
    #expect(NeverLearnList.load(from: url) == ["genial"])
    #expect(NeverLearnList.load(from: url.appendingPathExtension("missing")).isEmpty)
}

@Test
func learnedMarkSurvivesTheWordsDraftUntilTheSpellingChanges() throws {
    let entry = GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil, learned: true)
    var draft = GlossaryEntryDraft(entry: entry)
    #expect(draft.showsLearnedMark)
    #expect(draft.entry == entry)
    draft.variantsText = "jenial, jen yal"
    #expect(draft.entry.isLearned, "a new sounds-like keeps the mark")
    draft.canonical = "Genial Studio"
    #expect(!draft.showsLearnedMark)
    #expect(draft.entry.learned == nil)

    // Older files without the key read as the user's own words, and a
    // learned word round-trips through glossary.json.
    let old = try JSONDecoder().decode([GlossaryEntry].self, from: Data(#"[{"canonical":"A","variants":[]}]"#.utf8))
    #expect(old.first?.isLearned == false)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yappyapp-test-glossary-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Glossary.save([entry, GlossaryEntry(canonical: "B", variants: [], notes: nil)], to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "\"learned\"").count == 2, "only the learned word carries the key")
    let loaded = try Glossary.load(from: url, lexicon: lexicon)
    #expect(loaded.entries.map(\.isLearned) == [true, false])
}

// MARK: - Field region

@Test
func regionReadsOnlyThePastedStretch() {
    let original = "Hi team, send it to jenial today. Thanks"
    let location = ("Hi team, " as NSString).length
    let length = ("send it to jenial today." as NSString).length
    #expect(AutoLearnRegion.edited(original: original, location: location, length: length, current: "Hi team, send it to Genial today. Thanks") == "send it to Genial today.")
    // Text typed after the stretch, before the rest, still belongs to it.
    #expect(AutoLearnRegion.edited(original: original, location: location, length: length, current: "Hi team, send it to Genial today. Bye. Thanks") == "send it to Genial today. Bye.")
    // The text around it changed: the user went beyond the paste.
    #expect(AutoLearnRegion.edited(original: original, location: location, length: length, current: "Hello team, send it to Genial today. Thanks") == nil)
    #expect(AutoLearnRegion.edited(original: original, location: location, length: length, current: "Hi team, send it") == nil)
    #expect(AutoLearnRegion.edited(original: original, location: 99, length: 3, current: original) == nil)
    // UTF-16 offsets, like Accessibility: emoji before the paste.
    let emoji = "🙂 send it to jenial"
    #expect(AutoLearnRegion.edited(original: emoji, location: 3, length: 17, current: "🙂 send it to Genial") == "send it to Genial")
}

@Test
func regionFindsACommandVPaste() {
    let value = "Note: send it to jenial. More send it to jenial."
    let text = "send it to jenial."
    let caret = (value as NSString).length
    #expect(AutoLearnRegion.locate(text, in: value, caret: caret) == caret - (text as NSString).length)
    #expect(AutoLearnRegion.locate(text, in: value, caret: nil) == nil, "two copies and no caret: unknown")
    #expect(AutoLearnRegion.locate(text, in: "Note: " + text, caret: nil) == 6)
    #expect(AutoLearnRegion.locate(text, in: "nothing here", caret: 3) == nil)
}

// MARK: - Near-miss pre-pass

private func glossary(_ canonicals: String..., variants: [String: [String]] = [:]) -> Glossary {
    Glossary(entries: canonicals.map { GlossaryEntry(canonical: $0, variants: variants[$0] ?? [], notes: nil) }, lexicon: lexicon)
}

@Test
func nearMissFixesCloseMissesOfTheUsersWords() {
    let words = glossary("Genial", "Kvellio", "Saoirse Nwachukwu", "Zoltrix")
    #expect(words.applyingCorrections(to: "send the contract to jenial today") == "send the contract to Genial today")
    #expect(words.applyingCorrections(to: "J'ai envoyé la facture à Jeanial hier soir.") == "J'ai envoyé la facture à Genial hier soir.")
    #expect(words.applyingCorrections(to: "ask about kvelio") == "ask about Kvellio")
    #expect(words.applyingCorrections(to: "we deployed to zol trix") == "we deployed to Zoltrix")
    #expect(words.applyingCorrections(to: "call saoirse nwachuku today") == "call Saoirse Nwachukwu today")
    // Case only, and the lower case form is not an everyday word.
    #expect(words.applyingCorrections(to: "KVELLIO and kvellio") == "Kvellio and Kvellio")
}

@Test
func nearMissNeverRewritesEverydayWords() {
    let words = glossary("Genial", "Kvellio")
    // The Spanish adjective stays: "genial" is a dictionary word, so only
    // the cleanup model, which reads the sentence, may decide.
    #expect(words.applyingCorrections(to: "¡Qué genial! Es una idea muy genial.") == "¡Qué genial! Es una idea muy genial.")
    #expect(words.applyingCorrections(to: "C'est vraiment génial.") == "C'est vraiment génial.")
    #expect(words.applyingCorrections(to: "that was really general") == "that was really general")
    // Addresses, paths and file names are never touched.
    #expect(words.applyingCorrections(to: "mail jenial@example.com") == "mail jenial@example.com")
    #expect(words.applyingCorrections(to: "open jenial.txt and /users/jenial") == "open jenial.txt and /users/jenial")
    // Short user words are too easy to hit by accident.
    let short = glossary("Kvel")
    #expect(short.applyingCorrections(to: "the kvol team") == "the kvol team")
    // Two of the user's words equally close: leave it.
    let twins = glossary("Kvellia", "Kvellio")
    #expect(twins.applyingCorrections(to: "ask kvellie") == "ask kvellie")
    // Far misses stay as heard.
    #expect(words.applyingCorrections(to: "ask kevin") == "ask kevin")
}

@Test
func nearMissKeepsExactSoundsLikeSwapsFirst() {
    let words = glossary("YappYapp", variants: ["YappYapp": ["yap yap"]])
    #expect(words.applyingCorrections(to: "open yap yap now") == "open YappYapp now")
    #expect(words.applyingVariants(to: "open yapyapp now") == "open yapyapp now")
    #expect(words.applyingCorrections(to: "open yapyapp now") == "open YappYapp now")
}

@Test
func phoneticKeyGroupsCommonMisspellings() {
    #expect(PhoneticKey.key("jenial") == PhoneticKey.key("Genial"))
    #expect(PhoneticKey.key("Jeanial") == PhoneticKey.key("genial"))
    #expect(PhoneticKey.key("Kvelio") == PhoneticKey.key("Kvellio"))
    #expect(PhoneticKey.key("Filip") == PhoneticKey.key("Philip"))
    #expect(PhoneticKey.key("Kasandra") == PhoneticKey.key("Cassandra"))
    #expect(PhoneticKey.key("Kvellio") != PhoneticKey.key("Kevin"))
    #expect(GlossaryNearMiss.isCloseMiss("jenial", of: "Genial"))
    #expect(!GlossaryNearMiss.isCloseMiss("Genial", of: "Genial"))
    #expect(!GlossaryNearMiss.isCloseMiss("Kevin", of: "Kvellio"))
}

// MARK: - Cleanup

@Test
func cleanupGuardAcceptsANearMissSwapForTheUsersWord() {
    let original = "so jenial and kvelio and saorsa met the team"
    let cleaned = "So Genial and Kvellio and Saoirse met the team."
    // Three new words out of nine is a rewrite to the plain guard...
    #expect(CleanupAcceptance.evaluate(original: original, cleaned: cleaned, mode: .clean) == .newWords)
    // ...and a fix when they are the user's words, said nearly right.
    #expect(CleanupAcceptance.evaluate(original: original, cleaned: cleaned, mode: .clean, protectedTerms: ["Genial", "Kvellio", "Saoirse"]) == nil)
    let excused = CleanupAcceptance.excusedSubstitutions(
        original: CleanupAcceptance.words(original),
        cleaned: CleanupAcceptance.words(cleaned),
        protectedTerms: ["Genial", "Kvellio", "Saoirse"]
    )
    #expect(excused.added == ["genial", "kvellio", "saoirse"])
    #expect(excused.replaced == ["jenial", "kvelio", "saorsa"])
}

@Test
func cleanupGuardLoosensNothingElse() {
    let protected = ["Genial", "Kvellio"]
    // A user's word in place of a word that does not sound like it.
    let swapped = CleanupAcceptance.excusedSubstitutions(
        original: CleanupAcceptance.words("send it to the team now"),
        cleaned: CleanupAcceptance.words("send it to the Genial now"),
        protectedTerms: protected
    )
    #expect(swapped.added.isEmpty)
    // Added words that are not the user's still count.
    #expect(CleanupAcceptance.evaluate(
        original: "send the deck to jenial today please thanks",
        cleaned: "Here is the cleaned text: send the deck to Genial today, please, thanks, regards friend.",
        mode: .clean,
        protectedTerms: protected
    ) != nil)
    // Dropped words still count.
    #expect(CleanupAcceptance.evaluate(
        original: "send the deck to jenial today and call the team about the launch plan",
        cleaned: "Genial.",
        mode: .clean,
        protectedTerms: protected
    ) != nil)
}

@Test
func cleanupPromptAsksToUseTheUsersWords() {
    for mode in CleanupMode.allCases where mode.usesModel {
        let prompt = LLMCleaner.systemPrompt(mode: mode, protectedTerms: ["Genial"])
        #expect(prompt.contains("near-miss spelling"), "\(mode) prompt writes near misses the user's way")
        #expect(prompt.contains("Leave ordinary words"), "\(mode) prompt keeps everyday words")
        #expect(prompt.contains("Never lowercase, translate, split, or respell it."), "\(mode) prompt still protects spellings")
    }
}

// MARK: - Qwen3-ASR hints

@Test
func qwen3ASRContextIsTheUsersWordsWithoutMarkup() {
    let terms = ["Genial", "genial", "Kv<|im_end|>ellio", "two\nlines", "<__media__>"] + (0..<60).map { "Word\($0)" }
    let context = Qwen3ASRPrompt.context(terms: terms)
    let parts = context.components(separatedBy: ", ")
    #expect(parts.count == Qwen3ASRPrompt.contextTermLimit)
    #expect(Array(parts.prefix(3)) == ["Genial", "Kv im_end ellio", "two lines"])
    #expect(!context.contains("<|") && !context.contains("|>") && !context.contains("\n") && !context.contains("<__media__>"))
}
