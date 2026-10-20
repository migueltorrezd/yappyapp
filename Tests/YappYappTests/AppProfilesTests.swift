import Foundation
import Testing
@testable import YappYapp

private func profileConfig() -> AppConfig {
    var config = AppConfig.defaultConfig
    config.language = "en"
    config.modelPath = "parakeet://v3"
    config.autoPaste = true
    config.appProfiles = [
        AppProfile(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", language: "fr", pasteBehavior: .copyOnly)
    ]
    return config
}

@Test
func profileOverridesOnlyItsOwnApp() {
    let config = profileConfig()
    let slack = AppProfileResolver.resolve(
        base: config, bundleID: "com.tinyspeck.slackmacgap", lockedKeys: [], isModelInstalled: { _ in true }
    )
    #expect(slack.config.language == "fr")
    #expect(slack.autoPasteOverride == false)
    #expect(!slack.canUseWarmServer)

    let other = AppProfileResolver.resolve(
        base: config, bundleID: "com.apple.TextEdit", lockedKeys: [], isModelInstalled: { _ in true }
    )
    #expect(other.profile == nil)
    #expect(other.config.language == "en")
    #expect(other.autoPasteOverride == nil)
}

@Test
func managedLocksBeatProfiles() {
    let resolution = AppProfileResolver.resolve(
        base: profileConfig(),
        bundleID: "com.tinyspeck.slackmacgap",
        lockedKeys: [.language, .autoPaste],
        isModelInstalled: { _ in true }
    )
    #expect(resolution.config.language == "en")
    #expect(resolution.autoPasteOverride == nil)
    #expect(resolution.blocked == [.languageLocked, .pasteLocked])
}

@Test
func profilesDecodeLenientlyAndOlderConfigsHaveNone() throws {
    let legacy = #"{"modelPath":"parakeet://v3","language":"auto"}"#
    #expect(try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8)).appProfiles.isEmpty)

    let mixed = #"{"appProfiles":[{"bundleID":"com.apple.mail","pasteBehavior":"nope"},{"appName":"x"}]}"#
    let profiles = try JSONDecoder().decode(AppConfig.self, from: Data(mixed.utf8)).appProfiles
    #expect(profiles.map(\.bundleID) == ["com.apple.mail"])
    #expect(profiles.first?.pasteBehavior == nil)
    #expect(profiles.first?.followsSetup == true)
}

@Test
func badgeNamesProfileLanguageAndModel() {
    let config = profileConfig()
    // Parakeet v3 picks the language itself, so the badge says AUTO.
    #expect(DictationBadge.make(config: config, profile: nil).text == "AUTO · PARAKEET V3")
    let slack = config.appProfiles[0]
    #expect(DictationBadge.make(config: config, profile: slack).text == "SLACK · AUTO · PARAKEET V3")
}
