import Foundation
import SwiftUI
import Testing
@testable import YappYapp

@Test
func textSizeFallsBackToDefaultForUnknownValues() {
    #expect(BrutalTextSize(configValue: "large") == .large)
    #expect(BrutalTextSize(configValue: "default") == .standard)
    #expect(BrutalTextSize(configValue: "giant") == .standard)
}

@Test
func typeScaleFloorsCompactLabelsAndKeepsDefaults() {
    #expect(BrutalTypeScale.pointSize(base: 7.5, textSize: .small) == BrutalTypeScale.minimumPointSize)
    #expect(BrutalTypeScale.pointSize(base: 11.5, textSize: .standard) == 11.5)
    #expect(BrutalTypeScale.pointSize(base: 10, textSize: .larger) == 13)
}

@Test
func focusRingPaintsOnlyForKeyboardFocus() {
    #expect(BrutalFocusRing.isVisible(focused: true, focusedByPointer: false, keyboardNavigation: true))
    #expect(!BrutalFocusRing.isVisible(focused: true, focusedByPointer: true, keyboardNavigation: true))
    #expect(!BrutalFocusRing.isVisible(focused: false, focusedByPointer: false, keyboardNavigation: true))
    #expect(!BrutalFocusRing.isVisible(focused: true, focusedByPointer: false, keyboardNavigation: false))
    #expect(BrutalFocusRing.color == Brutal.ink)
}

@Test
@MainActor
func announcerMessagesStayShortAndSkipPasteHandledPhases() {
    #expect(AccessibilityAnnouncer.message(for: .recording) == "Listening.")
    #expect(AccessibilityAnnouncer.message(for: .transcribing) == "Transcribing.")
    #expect(AccessibilityAnnouncer.message(for: .error("Mic gone")) == "Needs attention. Mic gone")
    #expect(AccessibilityAnnouncer.message(for: .pasted) == nil)
    #expect(AccessibilityAnnouncer.defaultPoster(arguments: ["YappYapp", "--self-test"]) == nil)
}
