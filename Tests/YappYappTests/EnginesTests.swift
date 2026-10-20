import Foundation
import Testing
@testable import YappYapp

@Test
func fillerRemovalRepairsPunctuationAndKeepsUhOh() {
    #expect(FillerWords.removing(from: "I think um.") == "I think.")
    #expect(FillerWords.removing(from: "Bon, euh.") == "Bon.")
    #expect(FillerWords.removing(from: "Um. So we start.") == "So we start.")
    #expect(FillerWords.removing(from: "Uh-oh, that broke.") == "Uh-oh, that broke.")
    #expect(FillerWords.removing(from: "The UM campus.") == "The UM campus.")
}

@Test
func whisperTimeoutsScaleWithAudio() {
    #expect(TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 5, beamSearch: false) == 60)
    #expect(TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 600, beamSearch: true) > 600)
    #expect(TranscriptionTimeouts.whisperWatchdog(audioSeconds: 600, beamSearch: true)
        > TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 600, beamSearch: true))
    #expect(!WhisperServerFailure.shouldFallBackToCLI(URLError(.timedOut)))
    #expect(WhisperServerFailure.shouldFallBackToCLI(URLError(.cannotConnectToHost)))
}

@Test
func silenceHallucinationNeedsNearSilence() {
    #expect(WhisperOutputGuard.verdict(output: "Thank you.", prompt: "", nearSilence: true) == .dropHallucination)
    #expect(WhisperOutputGuard.verdict(output: "Thank you.", prompt: "", nearSilence: false) == .keep)
    #expect(WhisperOutputGuard.verdict(output: "Genial, LUMEX.", prompt: "Genial, LUMEX", nearSilence: false) == .dropPromptEcho)
}

@Test
func glossaryShortVariantsUseSafeBoundaries() {
    let glossary = Glossary(entries: [GlossaryEntry(canonical: "GPT", variants: ["jpt", "the"], notes: nil)])
    #expect(glossary.applyingCorrections(to: "ask jpt about the plan") == "ask GPT about the plan")
    #expect(glossary.applyingCorrections(to: "jpts") == "jpts")
}

@Test
func warmServerBackoffAndListenerOwnership() {
    var backoff = WhisperServerRestartBackoff()
    let now = Date()
    #expect(backoff.nextDelay(now: now) == 1)
    #expect(backoff.nextDelay(now: now) == 2)
    #expect(WhisperServerListenerCheck.ownsListener(listenerPIDs: [7], childPID: 7))
    #expect(!WhisperServerListenerCheck.ownsListener(listenerPIDs: [8], childPID: 7))
}
