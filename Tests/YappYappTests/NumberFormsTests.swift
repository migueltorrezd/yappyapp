import Foundation
import Testing
@testable import YappYapp

// NUMBERS: the deterministic pass, per language and per guard rail.

private func digits(_ text: String, _ language: NumberLanguage, protecting phrases: [String] = []) -> String {
    NumberForms.apply(text, plan: NumberPlan(style: .digits, language: language), protectedPhrases: phrases)
}

private func words(_ text: String, _ language: NumberLanguage, protecting phrases: [String] = []) -> String {
    NumberForms.apply(text, plan: NumberPlan(style: .words, language: language), protectedPhrases: phrases)
}

// MARK: - DIGITS, English

@Test(arguments: [
    ("twenty five people", "25 people"),
    ("twenty-five people", "25 people"),
    ("three point five percent", "3.5%"),
    ("about three point five percent of them", "about 3.5% of them"),
    ("one hundred and five", "105"),
    ("a hundred people", "100 people"),
    ("two thousand twenty five", "2025"),
    ("two thousand and five", "2005"),
    ("nineteen eighty four", "1984"),
    ("in twenty twenty five", "in 2025"),
    ("nineteen hundred", "1900"),
    ("ten", "10"),
    ("seventy two hours", "72 hours"),
    ("three days", "3 days"),
    ("five percent", "5%"),
    ("twenty five thousand", "25,000"),
    ("one million two hundred thousand", "1,200,000"),
    ("two million people", "2 million people"),
    ("three point five million", "3.5 million"),
    ("zero point five", "0.5"),
    ("forty two", "42"),
    ("ninety nine problems", "99 problems"),
    ("25 percent", "25%"),
    ("eleven", "11"),
])
func digitsEnglish(input: String, expected: String) {
    #expect(digits(input, .en) == expected)
}

@Test(arguments: [
    "one of the reasons",
    "one of them",
    "I have one",
    "two and a half",
    "a dozen",
    "thanks a million",
    "millions of people",
    "one on one",
    "one-on-one",
    "three thirty",
    "one two three",
    "five five five",
    "at one point",
    "twenty-something",
    "no one",
    "one day",
    "two people",
])
func digitsEnglishLeavesAlone(input: String) {
    #expect(digits(input, .en) == input)
}

@Test
func digitsEnglishKeepsNeighbors() {
    #expect(digits("Twenty five people came.", .en) == "25 people came.")
    #expect(digits("twenty and thirty", .en) == "20 and 30")
    #expect(digits("twenty, thirty", .en) == "20, 30")
    #expect(digits("one of the twenty five reasons", .en) == "one of the 25 reasons")
}

// MARK: - DIGITS, French

@Test(arguments: [
    ("vingt-cinq personnes", "25 personnes"),
    ("vingt cinq personnes", "25 personnes"),
    ("quatre-vingt-dix", "90"),
    ("quatre-vingts", "80"),
    ("quatre-vingt-onze", "91"),
    ("quatre-vingt-dix-neuf", "99"),
    ("soixante-dix", "70"),
    ("soixante et onze", "71"),
    ("soixante-quinze", "75"),
    ("vingt et un", "21"),
    ("vingt-et-un", "21"),
    ("dix-sept ans", "17 ans"),
    ("deux cents", "200"),
    ("cent euros", "100 euros"),
    ("trois virgule cinq pour cent", "3,5\u{202F}%"),
    ("trois virgule vingt-cinq", "3,25"),
    ("deux mille vingt-cinq", "2025"),
    ("mille neuf cent quatre-vingt-quatre", "1984"),
    ("deux millions", "2 millions"),
    ("cinq jours", "5 jours"),
    ("cinq pour cent", "5\u{202F}%"),
    ("nonante-neuf", "99"),
])
func digitsFrench(input: String, expected: String) {
    #expect(digits(input, .fr) == expected)
}

@Test(arguments: [
    "un ami",
    "une fois",
    "l'un d'eux",
    "un et deux",
    "c'est neuf",
    "des millions",
])
func digitsFrenchLeavesAlone(input: String) {
    #expect(digits(input, .fr) == input)
}

// MARK: - DIGITS, Spanish

@Test(arguments: [
    ("veinticinco personas", "25 personas"),
    ("treinta y cinco", "35"),
    ("veinte y cinco", "25"),
    ("ciento veinticinco", "125"),
    ("doscientos treinta y cinco", "235"),
    ("mil novecientos noventa y nueve", "1999"),
    ("dos mil veinticinco", "2025"),
    ("tres coma cinco por ciento", "3,5%"),
    ("tres punto cinco", "3.5"),
    ("cien por ciento", "100%"),
    ("dieciséis", "16"),
    ("veintidós años", "22 años"),
    ("cinco minutos", "5 minutos"),
    ("dos millones", "2 millones"),
    ("quinientas personas", "500 personas"),
])
func digitsSpanish(input: String, expected: String) {
    #expect(digits(input, .es) == expected)
}

@Test(arguments: [
    "uno de ellos",
    "en un momento",
    "una vez",
    "dos y tres",
    "un amigo",
])
func digitsSpanishLeavesAlone(input: String) {
    #expect(digits(input, .es) == input)
}

// MARK: - DIGITS, Dutch

@Test(arguments: [
    ("vijfentwintig mensen", "25 mensen"),
    ("tweeëntwintig", "22"),
    ("drieëndertig", "33"),
    ("vijf en twintig", "25"),
    ("honderdvijftig", "150"),
    ("tweeduizend vijfentwintig", "2025"),
    ("negentienhonderd vierentachtig", "1984"),
    ("drie komma vijf procent", "3,5%"),
    ("drie dagen", "3 dagen"),
    ("tien euro", "10 euro"),
    ("duizend", "1000"),
    ("tweehonderd", "200"),
    ("twee miljoen", "2 miljoen"),
])
func digitsDutch(input: String, expected: String) {
    #expect(digits(input, .nl) == expected)
}

@Test(arguments: [
    "een huis",
    "één keer",
    "vierkant",
    "Tienen",
    "twee en drie",
    "tweede",
])
func digitsDutchLeavesAlone(input: String) {
    #expect(digits(input, .nl) == input)
}

// MARK: - DIGITS guard rails

@Test
func digitsNeverTouchProtectedSpans() {
    // Glossary canonicals and snippet phrases.
    #expect(digits("we met at Twenty One Pilots", .en, protecting: ["Twenty One Pilots"]) == "we met at Twenty One Pilots")
    #expect(digits("add my twenty five cents", .en, protecting: ["my twenty five cents"]) == "add my twenty five cents")
    // URLs, emails and code-looking tokens.
    #expect(digits("see twenty_five and twenty-five", .en) == "see twenty_five and 25")
    #expect(digits("mail twenty@example.com", .en) == "mail twenty@example.com")
    #expect(digits("open https://example.com/twenty/five", .en) == "open https://example.com/twenty/five")
    #expect(digits("call twentyFive()", .en) == "call twentyFive()")
}

@Test
func digitsLeaveSnippetPhrasesAsSaved() {
    let library = SnippetLibrary(snippets: [Snippet(trigger: "twenty one pilots", expansion: "Twenty One Pilots (band)")])
    let text = "I love twenty one pilots and twenty five songs"
    let plan = NumberPlan(style: .digits, language: .en)
    let numbered = NumberForms.apply(text, plan: plan, protectedRanges: library.phraseRanges(in: text))
    #expect(numbered == "I love twenty one pilots and 25 songs")
    #expect(library.expanding(numbered) == "I love Twenty One Pilots (band) and 25 songs")
    #expect(library.phraseRanges(in: "twenty one pilots") == ["twenty one pilots".startIndex..<"twenty one pilots".endIndex])
}

// MARK: - WORDS

@Test(arguments: [
    ("25 people", "twenty-five people"),
    ("I have 3 cats", "I have three cats"),
    ("1,500 people", "one thousand five hundred people"),
    ("3.5 percent", "three point five percent"),
    ("25% off", "twenty-five percent off"),
    ("101 dalmatians", "one hundred one dalmatians"),
    ("25 people came.", "Twenty-five people came."),
])
func wordsEnglish(input: String, expected: String) {
    // The sentence-start capital is the only casing change.
    #expect(words(input, .en).lowercased() == expected.lowercased())
    #expect(words("25 people came.", .en) == "Twenty-five people came.")
    #expect(words("we saw 25 people", .en) == "we saw twenty-five people")
}

@Test(arguments: [
    "in 2025",
    "at 3:30",
    "version 2",
    "GPT-5",
    "the M5 chip",
    "iOS 26",
    "macOS 15",
    "3.14159",
    "call 555 1234",
    "06 12 34 56 78",
    "dial 0612345678",
    "1,000,000 users",
    "1. Eggs",
    "$25",
    "25 €",
    "12/05",
    "v2.1.3",
    "1st place",
    "the 90s",
    "room 4B",
])
func wordsLeavesAlone(input: String) {
    #expect(words(input, .en) == input)
}

@Test
func wordsOtherLanguages() {
    #expect(words("il y a 25 personnes", .fr) == "il y a vingt-cinq personnes")
    #expect(words("soit 3,5 %", .fr) == "soit trois virgule cinq pour cent")
    #expect(words("soit 3,25", .fr) == "soit trois virgule vingt-cinq")
    #expect(words("hay 25 personas", .es) == "hay veinticinco personas")
    #expect(words("son 3,5", .es) == "son tres coma cinco")
    #expect(words("son 3.5", .es) == "son tres punto cinco")
    #expect(words("er zijn 25 mensen", .nl) == "er zijn vijfentwintig mensen")
    #expect(words("er zijn 1.500 mensen", .nl) == "er zijn duizendvijfhonderd mensen")
    #expect(words("en 2026", .es) == "en 2026")
    #expect(words("25 personas.", .es) == "Veinticinco personas.")
}

@Test
func wordsNeverTouchProtectedSpans() {
    #expect(words("Area 51 is weird, 51 times", .en, protecting: ["Area 51"]) == "Area 51 is weird, fifty-one times")
}

// MARK: - Plans, language and the guard

@Test
func asSpokenAndUnknownLanguageLeaveEverything() {
    #expect(NumberForms.apply("twenty five", plan: .asSpoken) == "twenty five")
    #expect(NumberForms.apply("25", plan: NumberPlan(style: .words, language: nil)) == "25")
    #expect(NumberPlan.resolve(style: .digits, dictationLanguage: "de", transcript: "fünfundzwanzig Leute").language == nil)
    #expect(NumberPlan.resolve(style: .digits, dictationLanguage: "fr", transcript: "x").language == .fr)
    #expect(NumberPlan.resolve(style: .asSpoken, dictationLanguage: "en", transcript: "x") == .asSpoken)
}

@Test
func autoLanguageIsDetectedOnlyWhenSure() {
    #expect(NumberLanguage.resolve(dictationLanguage: "auto", transcript: "we need twenty five people for the event next week") == .en)
    #expect(NumberLanguage.resolve(dictationLanguage: "auto", transcript: "nous avons besoin de vingt-cinq personnes pour la soirée") == .fr)
    #expect(NumberLanguage.resolve(dictationLanguage: "auto", transcript: "necesitamos veinticinco personas para el evento") == .es)
    #expect(NumberLanguage.resolve(dictationLanguage: "auto", transcript: "we hebben vijfentwintig mensen nodig voor het feest") == .nl)
    #expect(NumberLanguage.resolve(dictationLanguage: "auto", transcript: "ok") == nil)
}

@Test
func canonicalFormComparesByValue() {
    #expect(NumberForms.canonical("twenty five people", language: .en) == "25 people")
    #expect(NumberForms.canonical("25,000 people", language: .en) == "25000 people")
    #expect(NumberForms.canonical("one of them", language: .en) == "1 of them")
    #expect(NumberForms.canonical("trois virgule cinq pour cent", language: .fr) == "3,5%")
}

@Test
func cleanupGuardAcceptsNumberFormsOnly() {
    let original = "we invited twenty five people and seventy two of them said yes to the big dinner party"
    let digitsRewrite = "We invited 25 people and 72 of them said yes to the big dinner party."
    // Before NUMBERS the guard had no reason to accept the form change; with
    // a number language it compares by value.
    #expect(CleanupAcceptance.evaluate(original: original, cleaned: digitsRewrite, mode: .clean, numberLanguage: .en) == nil)
    // A changed value is still new words.
    let rejected = CleanupAcceptance.evaluate(original: "we invited twenty five people and seventy two of them said yes", cleaned: "We invited 31 people and 18 of them said no.", mode: .clean, numberLanguage: .en)
    #expect(rejected != nil)
    // Nothing else is loosened: an added sentence is still rejected.
    let added = "We invited 25 people and 72 of them said yes to the big dinner party. Let me know if you need anything else from me today."
    #expect(CleanupAcceptance.evaluate(original: original, cleaned: added, mode: .clean, numberLanguage: .en) != nil)
    // Words the other way.
    #expect(CleanupAcceptance.evaluate(
        original: "nous avons invité 25 personnes et 72 ont dit oui pour le grand dîner",
        cleaned: "Nous avons invité vingt-cinq personnes et soixante-douze ont dit oui pour le grand dîner.",
        mode: .clean, numberLanguage: .fr
    ) == nil)
}

@Test
func cleanupPromptCarriesOneNumberLine() {
    let plain = LLMCleaner.systemPrompt(mode: .clean, protectedTerms: [])
    #expect(LLMCleaner.systemPrompt(mode: .clean, protectedTerms: [], numbers: .asSpoken) == plain)
    #expect(!plain.contains("5."))
    for mode in CleanupMode.allCases where mode.usesModel {
        let digitsPrompt = LLMCleaner.systemPrompt(mode: mode, protectedTerms: [], numbers: .digits)
        let wordsPrompt = LLMCleaner.systemPrompt(mode: mode, protectedTerms: [], numbers: .words)
        #expect(digitsPrompt.contains("5. Write numbers as digits"))
        #expect(wordsPrompt.contains("5. Write numbers as words"))
        // No example numbers in the prompt (PROMPT-TUNING LOG).
        #expect(!digitsPrompt.contains(where: \.isNumber) || digitsPrompt.filter(\.isNumber).allSatisfy { "12345".contains($0) })
    }
}

// MARK: - Config and profiles

@Test
func numberStyleDecodesAndRecovers() throws {
    #expect(AppConfig.defaultConfig.numbers == .asSpoken)
    var config = AppConfig.defaultConfig
    config.numbers = .digits
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(AppConfig.self, from: data).numbers == .digits)
    let older = #"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}"#
    #expect(try JSONDecoder().decode(AppConfig.self, from: Data(older.utf8)).numbers == .asSpoken)
    let unknown = older.replacingOccurrences(of: "}", with: #","numberStyle":"roman"}"#)
    #expect(try JSONDecoder().decode(AppConfig.self, from: Data(unknown.utf8)).numbers == .asSpoken)
    #expect(ConfigRecovery.fieldTypes["numberStyle"] != nil)
    let recovered = ConfigRecovery.decode(data: data, installDefaults: AppConfig.defaultConfig, lastSaved: { nil })
    #expect(recovered.config.numbers == .digits)
}

@Test
func profileOverridesNumbersUnlessLocked() {
    var base = AppConfig.defaultConfig
    base.appProfiles = [AppProfile(bundleID: "com.apple.Terminal", appName: "Terminal", numberStyle: "digits")]
    let free = AppProfileResolver.resolve(base: base, bundleID: "com.apple.Terminal", lockedKeys: [], isModelInstalled: { _ in true })
    #expect(free.config.numbers == .digits)
    #expect(free.blocked.isEmpty)
    let locked = AppProfileResolver.resolve(base: base, bundleID: "com.apple.Terminal", lockedKeys: [.numberStyle], isModelInstalled: { _ in true })
    #expect(locked.config.numbers == .asSpoken)
    #expect(locked.blocked == [.numbersLocked])
    #expect(!base.appProfiles[0].followsSetup)
    #expect(AppProfileCopy.summary(base.appProfiles[0], modelChoices: []).contains(NumberStyle.digits.label))
}

@Test
func managedNumberStyleLocksAndRestores() {
    let overrides = ManagedOverrides.read(from: StaticManagedPreferences([.numberStyle: .string("Digits")]))
    #expect(overrides.numberStyle == .digits)
    #expect(overrides.lockedKeys.contains(.numberStyle))
    let applied = overrides.apply(to: AppConfig.defaultConfig)
    #expect(applied.numbers == .digits)
    #expect(overrides.restoringUserValues(in: applied, from: AppConfig.defaultConfig).numbers == .asSpoken)
    #expect(ManagedOverrides.read(from: StaticManagedPreferences([.numberStyle: .string("roman")])).numberStyle == nil)
}
