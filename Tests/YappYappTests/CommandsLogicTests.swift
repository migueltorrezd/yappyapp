import Foundation
import Testing
@testable import YappYapp

@Test
func spokenCommandsTriggerOnlyAsTheirOwnClause() {
    #expect(SpokenCommands.apply(to: "Hi. New line. Bye.").text == "Hi.\nBye.")
    #expect(SpokenCommands.apply(to: "Hola. Nuevo párrafo. Chao.").text == "Hola.\n\nChao.")
    #expect(SpokenCommands.process("We need a new line of shoes.", enabled: true).text == "We need a new line of shoes.")
    #expect(SpokenCommands.process("Can you delete that?", enabled: true).text == "Can you delete that?")
}

@Test
func scratchThatOpeningADictationUndoesThePreviousOne() {
    let result = SpokenCommands.apply(to: "Efface ça.")
    #expect(result.undoPrevious)
    #expect(!result.hasContent)
    #expect(SpokenCommands.apply(to: "Maandag. Wis dat. Dinsdag.").text == "Dinsdag.")
}

@Test
func undoPlannerNeverGuesses() {
    let method = InsertionMethod.accessibility(location: 0, text: "Hi")
    #expect(InsertionUndoPlanner.plan(
        method: method, recordPID: 1, frontmostPID: 1, accessibilityTrusted: true,
        focusedElementMatches: true, currentValue: "Hi there"
    ) == .removeText(NSRange(location: 0, length: 2)))
    #expect(InsertionUndoPlanner.plan(
        method: method, recordPID: 1, frontmostPID: 1, accessibilityTrusted: true,
        focusedElementMatches: true, currentValue: "Oh Hi"
    ) == .refuse(.textChanged))
    #expect(InsertionUndoPlanner.plan(
        method: .keystroke, recordPID: 1, frontmostPID: 2, accessibilityTrusted: true,
        focusedElementMatches: false, currentValue: nil
    ) == .refuse(.appChanged(nil)))
}

@Test
func retryLastPrefersTheKeptFailedFile() {
    let memory = LastRecording(id: UUID(), wav: Data([0]), signalProfile: nil, failed: true)
    #expect(RetryLastPlanner.plan(phase: .idle, isProcessing: false, pasteInFlight: false, memory: memory, hasFailedDictation: true) == .retryFailed)
    #expect(RetryLastPlanner.plan(phase: .idle, isProcessing: false, pasteInFlight: false, memory: nil, hasFailedDictation: false) == .nothingYet)
}
