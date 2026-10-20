import Foundation
import Testing
@testable import YappYapp

@Test
func pasteTargetPolicyFollowsTheAppInFront() {
    #expect(PasteTargetPolicy.resolve(currentPID: 2) == .current)
    #expect(PasteTargetPolicy.resolve(currentPID: nil) == .stopTarget)
}

@Test
func outcomePhasesAreDistinct() {
    #expect(PasteOutcomePresenter.status(for: .pasted).phase == .pasted)
    #expect(PasteOutcomePresenter.status(for: .pastedBestEffort).phase == .sentUnconfirmed)
    #expect(PasteOutcomePresenter.status(for: .withheld(.secureInputActive)).phase
        == .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT · TEXT KEPT"))
    #expect(PasteOutcomePresenter.status(for: .copiedOnly(.focusUnclear)).phase
        == .notDelivered(headline: "COPIED ONLY", reason: "NO TEXT FIELD · ⌘V TO PASTE"))
}

@Test
func onlyConfirmedPasteCelebrates() {
    #expect(PetCelebrationPolicy.celebrates(.pasted))
    #expect(!PetCelebrationPolicy.celebrates(.sentUnconfirmed))
    #expect(!PetCelebrationPolicy.celebrates(.copied))
}

@Test
func countdownCoversOnlyTheLastTenSeconds() {
    #expect(HUDPresenter.countdown(elapsed: 50, limit: 60) == 10)
    #expect(HUDPresenter.countdown(elapsed: 49, limit: 60) == nil)
    #expect(HUDPresenter.countdown(elapsed: 60, limit: 60) == nil)
}

@Test
func notificationsHideTextUnlessAsked() {
    let hidden = DeliveryNotificationPolicy.notice(for: .copiedOnly(.focusUnclear), transcript: "secret plan", showText: false)
    #expect(!hidden.body.contains("secret plan"))
    let shown = DeliveryNotificationPolicy.notice(for: .copiedOnly(.focusUnclear), transcript: "secret plan", showText: true)
    #expect(shown.body.contains("secret plan"))
}

@Test
func concealedClipboardItemsAreNeverRestored() {
    #expect(!PasteboardPrivacy.isRestorable(itemTypes: [["org.nspasteboard.ConcealedType"]]))
    #expect(PasteboardPrivacy.isRestorable(itemTypes: [["public.utf8-plain-text"]]))
}

@Test
func layoutAwareKeyLookup() {
    let colemak: [UInt16: String] = [0x09: "v", 0x08: "c"]
    #expect(KeyboardLayoutKeyCode.keyCode(for: "v", translate: { colemak[$0] }) == 0x09)
    let dvorak: [UInt16: String] = [0x2F: "v", 0x09: "k"]
    #expect(KeyboardLayoutKeyCode.keyCode(for: "v", translate: { dvorak[$0] }) == 0x2F)
}

@Test
func indicatorBarDrawsNoWords() throws {
    // The compact indicator carries state with color, a glyph and the meter.
    // Words live on MIC, the menu bar and VoiceOver, never in the bar.
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/YappYapp/BrutalistHUDView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(!text.contains("Text("), "no Text view inside the indicator bar")
    for position in ["left", "right"] {
        #expect(HUDPosition(configValue: position).isVertical)
    }
    #expect(HUDPosition(configValue: "nowhere") == .bottom)
}
