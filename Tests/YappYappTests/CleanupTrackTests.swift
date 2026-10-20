import Foundation
import Testing
@testable import YappYapp

// LLM-CLEANUP (YA-10, missing feature 4): pure-logic coverage for modes,
// self-corrections, the acceptance guard and the readiness gate.

@Test
func cleanupModeFollowsLegacySwitchWhenMissing() {
    #expect(CleanupMode.resolve(stored: nil, legacyEnabled: true) == .clean)
    #expect(CleanupMode.resolve(stored: nil, legacyEnabled: false) == .verbatim)
    #expect(CleanupMode.resolve(stored: "notes", legacyEnabled: false) == .notes)
    #expect(CleanupMode.resolve(stored: "unknown", legacyEnabled: false) == .verbatim)
}

@Test
func selfCorrectionResolvesOnlyExplicitMarkers() {
    #expect(SelfCorrection.resolve("ship it on monday, no wait, on friday") == "ship it on friday")
    #expect(SelfCorrection.resolve("rendez-vous lundi, non je veux dire mardi") == "rendez-vous mardi")
    #expect(SelfCorrection.resolve("there is no wait time") == "there is no wait time")
}

@Test
func acceptanceRejectsAddedWordsAndKeepsTidies() {
    let original = "um so the launch moves to next week because the build is not signed yet"
    #expect(CleanupAcceptance.evaluate(
        original: original,
        cleaned: "So the launch moves to next week, because the build is not signed yet.",
        mode: .clean
    ) == nil)
    #expect(CleanupAcceptance.evaluate(
        original: original,
        cleaned: "Here is the cleaned version: the launch moves to next week because the build is not signed yet.",
        mode: .clean
    ) != nil)
}

@Test
func cleanupNeverDownloadsWithoutRuntime() {
    let readiness = CleanupReadiness.evaluate(
        mode: .clean,
        runtimeAvailable: false,
        modelVerified: false,
        downloadsAllowed: true,
        download: .idle
    )
    #expect(readiness == .needsRuntime)
    #expect(!readiness.canDownload)
    #expect(readiness.headline == "THIS COPY CAN'T RUN CLEANUP")
}

@Test
func completionRuntimeDropsLogDisable() {
    let completion = LLMCleaner.processArguments(tokenBudget: 128, mode: .email, runtime: .completion, modelPath: "/m.gguf")
    let cli = LLMCleaner.processArguments(tokenBudget: 128, mode: .email, runtime: .cli, modelPath: "/m.gguf")
    #expect(!completion.contains("--log-disable"))
    #expect(cli.contains("--log-disable"))
    #expect(completion.contains("/dev/stdin"))
}
