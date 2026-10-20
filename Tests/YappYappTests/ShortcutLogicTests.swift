import Carbon
import Foundation
import Testing
@testable import YappYapp

@Test
func hotKeyFreshPressAfterLostReleaseFires() {
    var filter = HotKeyRepeatFilter(repeatDelay: 0.5, repeatInterval: 0.083)
    let fired = [0, 0.5, 0.583, 1.8].map { filter.press(id: 1, at: $0) }
    // Repeats are swallowed; after the lost release the next real press fires.
    #expect(fired == [true, false, false, true])
}

@Test
func hybridModeTapLatchesAndHoldReleases() {
    var machine = DictationGestureMachine(mode: .hybrid, hybridThreshold: 0.3)
    let tapStart = machine.press(at: 0, isRecording: false)
    let tapRelease = machine.release(at: 0.1, isRecording: true)
    let tapStop = machine.press(at: 2, isRecording: true)
    let holdStart = machine.press(at: 5, isRecording: false)
    let holdRelease = machine.release(at: 6, isRecording: true)
    #expect(tapStart == .start)
    #expect(tapRelease == nil)
    #expect(tapStop == .stop)
    #expect(holdStart == .start)
    #expect(holdRelease == .stop)
}

@Test
func shortcutDefaultsKeepOptionSpaceToggle() throws {
    let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8))
    #expect(decoded == .default)
    #expect(decoded.mode == .toggle)
    #expect(decoded.chord(for: .toggleDictation) == .optionSpace)
}

@Test
func shortcutValidatorRejectsPlainLetters() {
    let letter = KeyChord(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
    #expect(!ShortcutValidator.validate(letter, for: .toggleDictation, in: .default).isAccepted)
}
