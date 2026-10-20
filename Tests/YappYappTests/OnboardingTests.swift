import Foundation
import Testing
@testable import YappYapp

// ONBOARDING: the step machine, the language picks and the advisor's
// language input. Like L10nTests, these never call L10n.apply: the helper
// starts in English.

private let fresh = OnboardingFacts(microphoneAuthorized: false, accessibilityTrusted: false, autoPasteWanted: true, speechModelReady: false)

private func mac(_ chip: String, gb: Int64, freeGB: Int64 = 200) -> HardwareProfile {
    HardwareProfile(chipName: chip, modelIdentifier: "Mac", memoryBytes: gb << 30, macOSVersion: "26.1",
                    freeDiskBytes: freeGB * 1_000_000_000, onBattery: false)
}

private func speechID(_ recommendations: [ModelRecommendation]) -> String? {
    for recommendation in recommendations {
        if case .speech(let id) = recommendation.choice { return id }
    }
    return nil
}

// MARK: - Step machine

@Test
func freshMacGetsSixSteps() {
    #expect(OnboardingFlow.steps(for: fresh) == [.languages, .models, .microphone, .autoPaste, .wordsAndSnippets, .tryIt])
}

@Test
func grantedPermissionsAndCopyOnlyLeaveTheirStepsOut() {
    var facts = fresh
    facts.microphoneAuthorized = true
    facts.accessibilityTrusted = true
    #expect(OnboardingFlow.steps(for: facts) == [.languages, .models, .wordsAndSnippets, .tryIt])
    facts = fresh
    facts.autoPasteWanted = false
    #expect(OnboardingFlow.steps(for: facts) == [.languages, .models, .microphone, .wordsAndSnippets, .tryIt])
}

@Test
func freshRunStartsOnLanguagesWithAutoAndTranslationOff() {
    let session = OnboardingFlow.start(facts: fresh, configLanguage: "auto", translateTarget: .off)
    #expect(session.current == .languages)
    #expect(session.spoken.isEmpty)
    #expect(session.translateTarget == .off)
    #expect(session.accepted == false)
    #expect(session.picks == nil)
}

@Test
func relaunchWithModelOnDiskResumesAtTheFirstOpenStep() {
    var facts = fresh
    facts.speechModelReady = true
    #expect(OnboardingFlow.start(facts: facts, configLanguage: "fr", translateTarget: .off).current == .microphone)
    facts.microphoneAuthorized = true
    let session = OnboardingFlow.start(facts: facts, configLanguage: "fr", translateTarget: .off)
    #expect(session.current == .autoPaste)
    #expect(session.accepted)
    #expect(session.spoken == ["fr"])
}

@Test
func nextSkipsPermissionsGrantedMeanwhileAndEndsWithNil() {
    var session = OnboardingFlow.start(facts: fresh, configLanguage: "auto", translateTarget: .off)
    session.current = .models
    var facts = fresh
    #expect(OnboardingFlow.next(session, facts: facts) == .microphone)
    facts.microphoneAuthorized = true
    #expect(OnboardingFlow.next(session, facts: facts) == .autoPaste)
    facts.accessibilityTrusted = true
    #expect(OnboardingFlow.next(session, facts: facts) == .wordsAndSnippets)
    session.current = .wordsAndSnippets
    #expect(OnboardingFlow.next(session, facts: facts) == .tryIt)
    session.current = .tryIt
    #expect(OnboardingFlow.next(session, facts: facts) == nil)
}

@Test
func backGoesOneStepAndNotBeforeTheFirst() {
    var session = OnboardingFlow.start(facts: fresh, configLanguage: "auto", translateTarget: .off)
    #expect(OnboardingFlow.previous(session) == nil)
    session.current = .autoPaste
    #expect(OnboardingFlow.previous(session) == .microphone)
}

@Test
func onlyPermissionStepsMoveOnByThemselves() {
    var facts = fresh
    #expect(OnboardingFlow.autoAdvances(.microphone, facts: facts) == false)
    facts.microphoneAuthorized = true
    facts.accessibilityTrusted = true
    #expect(OnboardingFlow.autoAdvances(.microphone, facts: facts))
    #expect(OnboardingFlow.autoAdvances(.autoPaste, facts: facts))
    #expect(OnboardingFlow.autoAdvances(.languages, facts: facts) == false)
    #expect(OnboardingFlow.autoAdvances(.tryIt, facts: facts) == false)
}

@Test
func skipIsOfferedOnlyWhereItIsSafe() {
    #expect(OnboardingFlow.skipTitle(for: .languages) == nil)
    #expect(OnboardingFlow.skipTitle(for: .tryIt) == nil)
    #expect(OnboardingFlow.skipTitle(for: .wordsAndSnippets) == nil)
    #expect(OnboardingFlow.skipTitle(for: .models) != nil)
    #expect(OnboardingFlow.skipTitle(for: .microphone) != nil)
    #expect(OnboardingFlow.skipTitle(for: .autoPaste) != nil)
}

@Test
func badgeCountsTheFixedStepList() {
    let steps = OnboardingFlow.steps(for: fresh)
    #expect(OnboardingFlow.badge(for: .microphone, in: steps) == "STEP 3 OF 6")
}

@Test
func everyStepHasATitleAndOneSentence() {
    for step in OnboardingStep.allCases {
        #expect(!OnboardingCopy.title(step).isEmpty)
        let detail = OnboardingCopy.detail(step)
        #expect(!detail.isEmpty)
        #expect(!detail.contains("\u{2014}"))
    }
}

// MARK: - Languages

@Test
func autoAndLanguagesExcludeEachOther() {
    var picks = OnboardingLanguages.toggle("fr", in: [])
    #expect(picks == ["fr"])
    picks = OnboardingLanguages.toggle("ja", in: picks)
    #expect(picks == ["fr", "ja"])
    #expect(OnboardingLanguages.toggle(OnboardingLanguages.auto, in: picks).isEmpty)
    #expect(OnboardingLanguages.toggle("fr", in: ["fr"]).isEmpty)
}

@Test
func dictationSettingTakesOneOfferedLanguageElseAuto() {
    #expect(OnboardingLanguages.configLanguage(for: ["nl"]) == "nl")
    #expect(OnboardingLanguages.configLanguage(for: ["fr", "es"]) == "auto")
    // Japanese only steers the model; the setting itself offers five codes.
    #expect(OnboardingLanguages.configLanguage(for: ["ja"]) == "auto")
    #expect(OnboardingLanguages.configLanguage(for: []) == "auto")
    #expect(OnboardingLanguages.initialPicks(configLanguage: "auto").isEmpty)
    #expect(OnboardingLanguages.initialPicks(configLanguage: "es") == ["es"])
}

@Test
func everySettingLanguageIsAlsoASpokenChoice() {
    let spoken = Set(LanguageCatalog.spokenLanguages.map(\.code))
    for option in LanguageCatalog.options where option.code != "auto" {
        #expect(spoken.contains(option.code))
    }
}

// MARK: - Advisor language input

@Test
func languageCoverageFollowsEngineAndVariant() throws {
    let tinyEnglish = try #require(ModelCatalog.option(for: "tiny-en"))
    #expect(tinyEnglish.languageCoverage == .only(["en"]))
    let turbo = try #require(ModelCatalog.option(for: "large-v3-turbo"))
    #expect(turbo.languageCoverage == .all)
    let japanese = try #require(ModelCatalog.option(for: "parakeet-ja"))
    #expect(japanese.languageCoverage.covers(["ja"]) == true)
    let v3 = try #require(ModelCatalog.option(for: "parakeet-v3"))
    #expect(v3.languageCoverage.covers(["fr", "nl", "uk"]) == true)
    #expect(v3.languageCoverage.covers(["zh"]) == false)
    #expect(SpeechLanguageCoverage.unknown.covers(["zh"]) == nil)
}

@Test
func noLanguageOrEuropeanLanguagesKeepTheDefault() {
    let profile = mac("Apple M4", gb: 16)
    let plain = ModelAdvisor.recommend(for: profile)
    #expect(speechID(ModelAdvisor.recommend(for: profile, languages: [])) == speechID(plain))
    #expect(speechID(ModelAdvisor.recommend(for: profile, languages: ["auto"])) == speechID(plain))
    #expect(speechID(plain) == ModelCatalog.recommendedID)
    if ModelCatalog.option(for: ModelCatalog.recommendedID)?.languageCoverage.covers(["fr", "nl"]) != false {
        #expect(speechID(ModelAdvisor.recommend(for: profile, languages: ["fr", "nl"])) == ModelCatalog.recommendedID)
    }
}

@Test
func speechPickNeverMissesAnAskedLanguage() throws {
    // Whatever the default is, the pick is never a model known to miss a
    // language that was asked for, as long as one fits.
    for languages: Set<String> in [["zh"], ["ja"], ["ja", "en"], ["ar", "fr"], ["ko"]] {
        let recommendations = ModelAdvisor.recommend(for: mac("Apple M3 Pro", gb: 36), languages: languages)
        let id = try #require(speechID(recommendations))
        let option = try #require(ModelCatalog.option(for: id))
        #expect(option.languageCoverage.covers(languages) != false, "\(languages) -> \(id)")
    }
}

@Test
func outsideParakeetLanguagesSteerToAModelThatFitsThisMac() {
    // Specific picks for today's catalog, where Parakeet Ultra is the default.
    guard ModelCatalog.recommendedID == "parakeet-ultra" else { return }
    // Qwen3-ASR leads for languages Parakeet misses: 1.7B with 16 GB or more.
    #expect(speechID(ModelAdvisor.recommend(for: mac("Apple M3 Pro", gb: 36), languages: ["zh"])) == "qwen3asr-1.7b")
    #expect(speechID(ModelAdvisor.recommend(for: mac("Apple M4", gb: 16), languages: ["ja", "en"])) == "qwen3asr-1.7b")
    #expect(speechID(ModelAdvisor.recommend(for: mac("Apple M1", gb: 8), languages: ["hi"])) == "qwen3asr-0.6b")
    // Without the llama.cpp runtime, Whisper covers them instead.
    #expect(speechID(ModelAdvisor.recommend(
        for: mac("Apple M3 Pro", gb: 36), languages: ["zh"], qwen3ASRAvailable: false
    )) == "large-v3-turbo")
    // 8 GB and no Qwen3-ASR: no Whisper model over 1 GB, so Small.
    #expect(speechID(ModelAdvisor.recommend(
        for: mac("Apple M1", gb: 8), languages: ["hi"], qwen3ASRAvailable: false
    )) == "small")
}

@Test
func noOtherRuntimeKeepsTheDefaultAndSaysWhy() {
    guard ModelCatalog.recommendedID == "parakeet-ultra" else { return }
    let recommendations = ModelAdvisor.recommend(
        for: mac("Apple M4", gb: 16), languages: ["zh"], whisperAvailable: false, qwen3ASRAvailable: false
    )
    #expect(speechID(recommendations) == "parakeet-ultra")
    #expect(recommendations.first?.reason.contains("中文") == true)
}

@Test
func noRoomForTheCoveringModelKeepsTheDefault() {
    guard ModelCatalog.recommendedID == "parakeet-ultra" else { return }
    // 5 GB free: no download leaves the 5 GB margin.
    let tight = mac("Apple M4", gb: 16, freeGB: 5)
    let recommendations = ModelAdvisor.recommend(for: tight, languages: ["zh"])
    #expect(recommendations.first?.kind == .speech)
    #expect(speechID(recommendations) == "parakeet-ultra" || recommendations.first?.choice == RecommendedChoice.none)
}

// MARK: - DETECT BEST MODELS plan

@Test
func translationStaysOffUntilATargetIsPicked() {
    let recommendations = ModelAdvisor.recommend(for: mac("Apple M5 Pro", gb: 48))
    let off = OnboardingPlan.picks(from: recommendations, translateTarget: .off, llamaRuntimeAvailable: true)
    #expect(off.translationModel == nil)
    #expect(off.cleanup == .clean)
    let french = OnboardingPlan.picks(from: recommendations, translateTarget: .fr, llamaRuntimeAvailable: true)
    #expect(french.translationModel == .hyMT2Best)
}

@Test
func withoutTheLlamaRuntimeCleanupAndTranslationStayOff() {
    let recommendations = ModelAdvisor.recommend(for: mac("Apple M5 Pro", gb: 48))
    let picks = OnboardingPlan.picks(from: recommendations, translateTarget: .en, llamaRuntimeAvailable: false)
    #expect(picks.cleanup == .verbatim)
    #expect(picks.translationModel == nil)
}

@Test
func totalCountsOnlyWhatIsNotOnThisMac() throws {
    let picks = OnboardingPicks(speechID: "parakeet-v3", cleanup: .clean, translationModel: .hyMT2Fast)
    let speechBytes = try #require(ModelCatalog.option(for: "parakeet-v3")?.downloadBytes)
    let translationBytes = try #require(TranslationCatalog.model(.hyMT2Fast).download?.sizeBytes)
    let nothingInstalled = OnboardingPlan.rows(picks: picks, recommendations: [], installed: InstalledModels(), translateTarget: .en, llamaRuntimeAvailable: true)
    #expect(nothingInstalled.count == 3)
    #expect(OnboardingPlan.totalBytes(nothingInstalled) == speechBytes + OnboardingPlan.cleanupModelBytes + translationBytes)
    let speechHere = OnboardingPlan.rows(picks: picks, recommendations: [], installed: InstalledModels(speechIDs: ["parakeet-v3"]), translateTarget: .en, llamaRuntimeAvailable: true)
    #expect(OnboardingPlan.totalBytes(speechHere) == OnboardingPlan.cleanupModelBytes + translationBytes)
}

@Test
func applyingPicksWritesLanguageCleanupAndTranslation() {
    let picks = OnboardingPicks(speechID: "parakeet-v3", cleanup: .clean, translationModel: .hyMT2Fast)
    let config = OnboardingPlan.applying(picks, spoken: ["es"], translateTarget: .en, to: AppConfig.defaultConfig)
    #expect(config.language == "es")
    #expect(config.cleanup == .clean)
    #expect(config.translation == .en)
    #expect(config.translationModelID == .hyMT2Fast)
    let off = OnboardingPlan.applying(OnboardingPicks(speechID: "parakeet-v3", cleanup: .verbatim, translationModel: nil),
                                      spoken: ["es", "fr"], translateTarget: .en, to: AppConfig.defaultConfig)
    #expect(off.language == "auto")
    #expect(off.translation == .off)
}

// MARK: - Download strip

@Test
func downloadLinesSayWhereEachDownloadIs() {
    #expect(OnboardingDownloads.speechLine(name: "Parakeet", ready: false, progress: 0.42, error: nil).status == "42%")
    let failed = OnboardingDownloads.speechLine(name: "Parakeet", ready: false, progress: nil, error: DownloadErrorCopy.offline)
    #expect(failed.isError)
    #expect(OnboardingDownloads.speechLine(name: "Parakeet", ready: true, progress: nil, error: nil).isDone)
    #expect(OnboardingDownloads.extraLine(name: "Cleanup", phase: .idle, verified: false, queued: false) == nil)
    #expect(OnboardingDownloads.extraLine(name: "Cleanup", phase: .idle, verified: false, queued: true)?.status == "AFTER THE SPEECH MODEL")
    #expect(OnboardingDownloads.extraLine(name: "Cleanup", phase: .failed("x"), verified: false, queued: false)?.isError == true)
}

// MARK: - WORDS AND SNIPPETS

private let genial = GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)
private let email = Snippet(trigger: "my email", expansion: "jane@company.com")

@Test
func wordsStepComesRightBeforeTryItAndCannotBeSkipped() {
    let steps = OnboardingFlow.steps(for: fresh)
    let words = steps.firstIndex(of: .wordsAndSnippets)
    let tryIt = steps.firstIndex(of: .tryIt)
    #expect(words != nil && tryIt != nil && words! + 1 == tryIt!)
    #expect(OnboardingFlow.isSatisfied(.wordsAndSnippets, facts: fresh) == false)
    #expect(OnboardingFlow.autoAdvances(.wordsAndSnippets, facts: fresh) == false)
}

@Test
func continueWaitsForOneWordAndOneSnippet() {
    var session = OnboardingFlow.start(facts: fresh, configLanguage: "auto", translateTarget: .off)
    session.current = .wordsAndSnippets
    #expect(OnboardingFlow.canContinue(session) == false)
    session.addedWord = genial
    #expect(OnboardingFlow.canContinue(session) == false)
    session.addedWord = nil
    session.addedSnippet = email
    #expect(OnboardingFlow.canContinue(session) == false)
    session.addedWord = genial
    #expect(OnboardingFlow.canContinue(session))
    // BACK is always there.
    #expect(OnboardingFlow.previous(session) == .autoPaste)
    // Every other step continues as before.
    session.addedWord = nil
    session.current = .languages
    #expect(OnboardingFlow.canContinue(session))
}

@Test
func wordsUseTheWordsTabRules() {
    #expect(OnboardingWords.wordIssue(canonical: "  ", variantsText: "", existing: []) != nil)
    #expect(OnboardingWords.wordIssue(canonical: "yappyapp", variantsText: "", existing: Glossary.defaultEntries) != nil)
    #expect(OnboardingWords.wordIssue(canonical: "Genial", variantsText: "the", existing: []) != nil)
    #expect(OnboardingWords.wordIssue(canonical: "Genial", variantsText: "jenial, jen yal", existing: Glossary.defaultEntries) == nil)
    let entry = OnboardingWords.entry(canonical: " Genial ", variantsText: "jenial, , jen yal")
    #expect(entry == GlossaryEntry(canonical: "Genial", variants: ["jenial", "jen yal"], notes: nil))
    #expect(OnboardingWords.adding(entry, to: Glossary.defaultEntries).first == entry)
}

@Test
func snippetsUseTheWordsTabRules() {
    #expect(OnboardingWords.snippetIssue(trigger: "", expansion: "", existing: [], glossary: []) != nil)
    #expect(OnboardingWords.snippetIssue(trigger: "email", expansion: "x", existing: [], glossary: []) != nil)
    #expect(OnboardingWords.snippetIssue(trigger: "my email", expansion: "", existing: [], glossary: []) != nil)
    #expect(OnboardingWords.snippetIssue(trigger: "My Email", expansion: "x", existing: [email], glossary: []) != nil)
    #expect(OnboardingWords.snippetIssue(trigger: "yap yap", expansion: "x", existing: [], glossary: Glossary.defaultEntries) != nil)
    #expect(OnboardingWords.snippetIssue(trigger: "my email", expansion: "jane@company.com", existing: [], glossary: Glossary.defaultEntries) == nil)
    let snippet = OnboardingWords.snippet(trigger: "  my email ", expansion: "jane@company.com")
    #expect(snippet.trigger == "my email")
    #expect(OnboardingWords.adding(snippet, to: [email]).first == snippet)
}

@Test
func placeholdersSuggestTheUsersSurname() {
    #expect(OnboardingWords.wordPlaceholder(fullName: "Miguel Torrez") == "Torrez")
    #expect(OnboardingWords.wordPlaceholder(fullName: "Miguel") == GlossaryPlaceholders.writeItAs)
    #expect(OnboardingWords.wordPlaceholder(fullName: "") == GlossaryPlaceholders.writeItAs)
    #expect(OnboardingWords.wordPlaceholder(fullName: "Jo Li") == GlossaryPlaceholders.writeItAs)
}

@Test
func confirmationsSayWhatWasSavedWithoutDashes() {
    #expect(OnboardingWords.wordConfirmation(genial).contains("jenial"))
    #expect(OnboardingWords.wordConfirmation(GlossaryEntry(canonical: "Genial", variants: [], notes: nil)).contains("Genial"))
    #expect(OnboardingWords.snippetConfirmation(email).contains("jane@company.com"))
    let long = Snippet(trigger: "my signature", expansion: String(repeating: "Best regards from the team\n", count: 4))
    #expect(OnboardingWords.snippetConfirmation(long).hasSuffix("…\"."))
    for text in [OnboardingWords.wordConfirmation(genial), OnboardingWords.snippetConfirmation(email),
                 OnboardingWords.tryItSentence(word: genial, snippet: email)] {
        #expect(!text.contains("\u{2014}"))
    }
    #expect(OnboardingWords.tryItSentence(word: genial, snippet: email) == "Genial, here is my email.")
}

@Test
func tryItSeesTheWordAndTheExpandedSnippet() {
    let both = OnboardingTryItCheck(text: "Genial, here is jane@company.com.", word: genial, snippet: email)
    #expect(both.wordFound && both.snippetFound)
    let bothOK = both.lines(word: genial, snippet: email).allSatisfy(\.ok)
    #expect(bothOK)

    let noSnippet = OnboardingTryItCheck(text: "Genial, here is my e-mail.", word: genial, snippet: email)
    #expect(noSnippet.wordFound)
    #expect(noSnippet.snippetFound == false)
    let lines = noSnippet.lines(word: genial, snippet: email)
    #expect(lines[1].ok == false)
    #expect(lines[1].text.contains("my email"))

    // Misheard: the glossary did not fire, so the word is not there.
    let misheard = OnboardingTryItCheck(text: "Jenny all, here is jane@company.com.", word: genial, snippet: email)
    #expect(misheard.wordFound == false)
    #expect(misheard.lines(word: genial, snippet: email)[0].text.contains("SOUNDS LIKE"))

    // A word that only shows up inside the pasted text does not count.
    let inside = Snippet(trigger: "my email", expansion: "hello@genial.com Genial")
    let only = OnboardingTryItCheck(text: "here is hello@genial.com Genial", word: genial, snippet: inside)
    #expect(only.snippetFound)
    #expect(only.wordFound == false)
}

// MARK: - DROPDOWN-FLOAT placement

@Test
func dropdownOpensUnderTheFieldWhenThereIsRoom() {
    let field = CGRect(x: 30, y: 120, width: 300, height: 26)
    let place = BrutalMenuPlacement.frame(field: field, bounds: CGSize(width: 440, height: 596), wantedHeight: BrutalMenuPlacement.wantedHeight(rows: 5))
    #expect(place.above == false)
    #expect(place.x == 30)
    #expect(place.width == 300)
    // The list shares the field's bottom border, so the two read as one.
    #expect(place.edge == field.maxY - Brutal.border)
    #expect(place.maxHeight > BrutalMenuPlacement.wantedHeight(rows: 5))
}

@Test
func dropdownFlipsUpNearTheBottomAndScrollsWhenLong() {
    let field = CGRect(x: 30, y: 520, width: 300, height: 26)
    let place = BrutalMenuPlacement.frame(field: field, bounds: CGSize(width: 440, height: 596), wantedHeight: BrutalMenuPlacement.wantedHeight(rows: 8))
    #expect(place.above)
    #expect(place.edge == field.minY + Brutal.border)
    #expect(place.maxHeight == field.minY - BrutalMenuPlacement.margin)
    // Thirty rows never fit; the list keeps its room and scrolls inside.
    let long = BrutalMenuPlacement.frame(field: CGRect(x: 0, y: 100, width: 300, height: 26), bounds: CGSize(width: 440, height: 596), wantedHeight: BrutalMenuPlacement.wantedHeight(rows: 30))
    #expect(long.above == false)
    #expect(long.maxHeight < BrutalMenuPlacement.wantedHeight(rows: 30))
}
