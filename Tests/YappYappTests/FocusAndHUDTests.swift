import AppKit
import Foundation
import Testing
@testable import YappYapp

// FOCUS-AT-DELIVERY: the text goes to the element focused at delivery, in the
// app in front at delivery. These pin the pure rules behind that.

private let ghostty: pid_t = 501
private let notes: pid_t = 600
private let own: pid_t = 42

private func facts(
    target: pid_t? = ghostty,
    front: pid_t?,
    focused: pid_t?,
    active: Bool = false,
    key: Bool = false
) -> DeliveryFocusPolicy.Facts {
    DeliveryFocusPolicy.Facts(
        targetPID: target,
        frontmostPID: front,
        focusedAppPID: focused,
        yappyappActive: active,
        yappyappHasKeyWindow: key
    )
}

@Test
func targetReallyInFrontIsLeftAlone() {
    // Re-activating Ghostty with native tabs reshuffles them; skip it only
    // when it truly owns the keyboard.
    #expect(!DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty)))
    #expect(DeliveryFocusPolicy.isReady(facts(front: ghostty, focused: ghostty)))
    // AX could not say who has the keyboard: keep the frontmost answer.
    #expect(!DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: nil)))
}

@Test
func frontmostIsNotEnoughWhenTheKeyboardIsElsewhere() {
    // Ghostty listed in front but its window not key (hollow cursor).
    #expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: own)))
    #expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: notes)))
    // Any YappYapp window active or key: the Cmd+V would land in YappYapp.
    #expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty, active: true)))
    #expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty, key: true)))
    // Another app in front.
    #expect(DeliveryFocusPolicy.needsActivation(facts(front: notes, focused: notes)))
    // No target: nothing to activate.
    #expect(!DeliveryFocusPolicy.needsActivation(facts(target: nil, front: notes, focused: notes)))
}

@Test
func onlyElementsReadAtDeliveryReceiveText() {
    // The field captured at the stop is never written: the user may have
    // clicked into another one since (text box A, then B).
    #expect(!DeliveryFocusPolicy.admits(.captured, elementPID: notes, targetPID: notes, ownPID: own))
    #expect(DeliveryFocusPolicy.admits(.targetFocused, elementPID: notes, targetPID: notes, ownPID: own))
    #expect(!DeliveryFocusPolicy.admits(.targetFocused, elementPID: notes, targetPID: nil, ownPID: own))
    #expect(DeliveryFocusPolicy.admits(.systemFocused, elementPID: notes, targetPID: notes, ownPID: own))
    #expect(!DeliveryFocusPolicy.admits(.systemFocused, elementPID: ghostty, targetPID: notes, ownPID: own))
    #expect(!DeliveryFocusPolicy.admits(.systemFocused, elementPID: own, targetPID: nil, ownPID: own))
    #expect(!DeliveryFocusPolicy.admits(.systemFocused, elementPID: nil, targetPID: notes, ownPID: own))
}

@Test
func lateDeactivationNeverReplacesTheAppTheUserMovedTo() {
    // Switching Notes -> Ghostty: Ghostty's activation can arrive before
    // Notes' deactivation. Notes must not become the target again.
    #expect(!PasteTargetMemory.deactivationRefreshes(deactivatedPID: notes, rememberedPID: ghostty))
    #expect(PasteTargetMemory.deactivationRefreshes(deactivatedPID: ghostty, rememberedPID: ghostty))
    #expect(PasteTargetMemory.deactivationRefreshes(deactivatedPID: notes, rememberedPID: nil))
}

@Test
func focusOwnersAreClassified() {
    #expect(FocusOwner.classify(pid: ghostty, targetPID: ghostty, ownPID: own) == .target)
    #expect(FocusOwner.classify(pid: own, targetPID: ghostty, ownPID: own) == .yappyapp)
    #expect(FocusOwner.classify(pid: notes, targetPID: ghostty, ownPID: own) == .other)
    #expect(FocusOwner.classify(pid: nil, targetPID: ghostty, ownPID: own) == .unknown)
}

@Test
func deliveryTrailNamesWhoHeldTheKeyboard() {
    var trail = DeliveryTrail()
    trail.record(DeliveryTrailEntry(
        date: Date(timeIntervalSince1970: 0),
        bundleIdentifier: "com.mitchellh.ghostty",
        targetKind: .terminal,
        decision: "commandV",
        outcome: "pastedBestEffort",
        activation: .activated,
        frontmostMatchedTarget: true,
        restoresClipboard: true,
        secureInputHolder: nil,
        focus: DeliveryFocusReport(
            yappyappActive: true,
            yappyappKeyWindow: false,
            focusedApp: .other,
            focusedAppBundle: "com.example.app",
            focusedElement: .unknown
        )
    ))
    let line = trail.reportLines().first ?? ""
    #expect(line.contains("yappyappActive=yes"))
    #expect(line.contains("keyWindow=none"))
    #expect(line.contains("focusedApp=other(com.example.app)"))
    #expect(line.contains("focusedElement=unknown"))
}

// MARK: - Indicator window

@Test
func indicatorTakesClicksOnTheBarOnly() {
    for position in [HUDPosition.bottom, .top, .left, .right] {
        let size = position.windowSize
        let frame = NSRect(origin: NSPoint(x: 100, y: 200), size: size)
        let bar = position.interactiveRect(windowSize: size)
        #expect(NSRect(origin: .zero, size: size).contains(bar), "\(position): the bar is inside its window")
        let onBar = NSPoint(x: frame.minX + bar.midX, y: frame.minY + bar.midY)
        #expect(HUDMousePolicy.takesClicks(phaseAcceptsMouse: true, pointer: onBar, windowFrame: frame, position: position))
        #expect(!HUDMousePolicy.takesClicks(phaseAcceptsMouse: false, pointer: onBar, windowFrame: frame, position: position),
                "\(position): click-through while nothing is clickable")
    }
    // The pet's headroom above the bottom bar is click-through, so a click
    // on a terminal prompt under it reaches the terminal.
    let size = HUDPosition.bottom.windowSize
    let frame = NSRect(origin: .zero, size: size)
    #expect(!HUDMousePolicy.takesClicks(phaseAcceptsMouse: true, pointer: NSPoint(x: size.width / 2, y: size.height - 10), windowFrame: frame, position: .bottom))
    #expect(!HUDMousePolicy.takesClicks(phaseAcceptsMouse: true, pointer: NSPoint(x: 2, y: 2), windowFrame: frame, position: .bottom))
}

@Test
func petHasAPlaceAtEveryEdge() {
    #expect(HUDPosition.bottom.petPlacement == .standing)
    #expect(HUDPosition.top.petPlacement == .hanging)
    #expect(HUDPosition.left.petPlacement == .perched(.leading))
    #expect(HUDPosition.right.petPlacement == .perched(.trailing))
    #expect(HUDPosition.off.petPlacement == nil)
    // Top: the window hangs from the top of the visible frame, so nothing
    // reaches into the menu bar or the notch.
    let screen = NSRect(x: 0, y: 25, width: 1512, height: 920)
    let top = HUDPosition.top.windowOrigin(in: screen)
    #expect(top.y + HUDPosition.top.windowSize.height <= screen.maxY)
    // Sides: wide enough for the widest pet (23 sprite pixels at 2pt).
    #expect(HUDPosition.left.windowSize.width >= 46)
    let left = HUDPosition.left.windowOrigin(in: screen)
    #expect(left.y + HUDPosition.left.windowSize.height <= screen.maxY)
    #expect(left.y >= screen.minY)
}

// MARK: - HUD returns to idle

@Test
func transientOutcomesNeverTakeOverADictation() {
    #expect(HUDTransientPolicy.phaseToShow(.copied, over: .idle) == .copied)
    #expect(HUDTransientPolicy.phaseToShow(.copied, over: .pasted) == .copied)
    #expect(HUDTransientPolicy.phaseToShow(.copied, over: .recording) == nil)
    #expect(HUDTransientPolicy.phaseToShow(.copied, over: .transcribing) == nil)
    #expect(HUDTransientPolicy.phaseToShow(.error("x"), over: .canceled) == nil)
    #expect(HUDTransientPolicy.holdSeconds(for: .copied) == PasteOutcomePresenter.holdSeconds(for: .copied))
}

/// Every phase set outside a dictation must schedule its return to idle.
/// A source guard: any `state.phase = ` that sets an outcome (not idle,
/// recording, transcribing or canceled, which own their own lifecycle) must
/// be followed within five lines by `scheduleReturnToIdle`.
@Test
func everyOutcomePhaseSchedulesAReturnToIdle() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/YappYapp")
    let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("SelfTests") && $0 != "RenderGallery.swift" }
    let lifecycle = [".idle", ".recording", ".transcribing", ".canceled"]
    var offenders: [String] = []
    for file in files {
        let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: "state.phase = ") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if lifecycle.contains(where: { value == $0 }) { continue }
            let window = lines[index..<min(lines.count, index + 6)].joined(separator: "\n")
            if !window.contains("scheduleReturnToIdle") {
                offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(offenders.isEmpty, "phases that never shrink back: \(offenders)")
}
