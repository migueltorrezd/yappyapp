import Foundation
import Testing
@testable import YappYapp

// Pure logic owned by the "l10n" track. These tests never call L10n.apply:
// swift-testing runs in parallel and other suites read English copy.

@Test
func systemLanguagePicksTheFirstSupportedPreference() {
    #expect(L10n.resolve("system", preferredLanguages: ["pt-BR", "nl-NL", "fr-FR"]) == "nl")
    #expect(L10n.resolve("system", preferredLanguages: ["es-SV"]) == "es")
    #expect(L10n.resolve("system", preferredLanguages: ["zh-Hans"]) == "en")
    #expect(L10n.resolve("fr", preferredLanguages: ["es-SV"]) == "fr")
}

@Test
func everyLanguageHasTheSameKeys() {
    let english = Set(L10n.table(for: "en").keys)
    #expect(english.count > 900)
    for language in ["fr", "es", "nl"] {
        #expect(Set(L10n.table(for: language).keys) == english, "\(language) keys")
    }
}

@Test
func lookupsFallBackToEnglishThenTheKey() {
    #expect(L10n.string("SETUP", language: "nl") == "OPTIES")
    #expect(L10n.string("SETUP", language: "de") == "SETUP")
    #expect(L10n.string("Not a key at all", language: "fr") == "Not a key at all")
    #expect(L10n.format("Step %@ of %@", ["2", "3"], language: "es") == "Paso 2 de 3")
}

@Test
func pluralsUseEachLanguagesRules() {
    #expect(L10n.plural("%lld DAYS", 1, language: "en") == "1 DAY")
    #expect(L10n.plural("%lld DAYS", 0, language: "fr") == "0 JOUR")
    #expect(L10n.plural("%lld DAYS", 0, language: "nl") == "0 DAGEN")
    #expect(L10n.plural("%lld dictations", 2, language: "es") == "2 dictados")
    #expect(L10n.plural("%lld dictations", 1, language: "fr") == "1 dictée")
}

@Test
func spanishStaysLatinAmerican() {
    let spanish = L10n.table(for: "es").values.joined(separator: " ").lowercased()
    for spainOnly in ["vosotros", "ordenador", "vale.", "móvil"] {
        #expect(!spanish.contains(spainOnly), "\(spainOnly)")
    }
}
