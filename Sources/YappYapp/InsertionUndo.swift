import AppKit
import ApplicationServices
import Carbon
import Foundation

// COMMANDS (missing feature 8): undo the last insertion. ClipboardInjector
// records how each dictation went in; this file decides how to take it back
// and does it. Text written through Accessibility is removed exactly, and
// only while it is still where YappYapp put it. Text pasted with Cmd+V is
// undone with Cmd+Z, and only while that same app is in front. Anything else
// gets an explanation instead of a guess.

enum InsertionMethod: Equatable {
    /// Written through the AX value. `location` is the UTF-16 offset and
    /// `text` the exact string written, spacing included.
    case accessibility(location: Int, text: String)
    /// Written through AX, but the field reformatted it (smart quotes,
    /// spacing), so the exact range is unknown.
    case accessibilityNormalized
    /// Pasted with a synthetic Cmd+V: the app's own undo can take it back.
    case keystroke
}

struct InsertionRecord {
    let method: InsertionMethod
    let processIdentifier: pid_t?
    let applicationName: String?
    /// The element written into. nil for a Cmd+V paste.
    let element: AXUIElement?
    let date: Date
}

enum InsertionUndoRefusal: Equatable {
    case nothingToUndo
    case appChanged(String?)
    case textChanged
    case needsPermission
    case busy
    case modifiersHeld
}

enum InsertionUndoPlan: Equatable {
    case removeText(NSRange)
    case sendCommandZ
    case refuse(InsertionUndoRefusal)
}

enum InsertionUndoOutcome: Equatable {
    case removed
    case sentUndoKey
    case refused(InsertionUndoRefusal)
}

enum InsertionUndoPlanner {
    /// Pure decision. `focusedElementMatches` and `currentValue` describe the
    /// focused field of the app in front at undo time.
    static func plan(
        method: InsertionMethod?,
        recordPID: pid_t?,
        frontmostPID: pid_t?,
        accessibilityTrusted: Bool,
        focusedElementMatches: Bool,
        currentValue: String?
    ) -> InsertionUndoPlan {
        guard let method else { return .refuse(.nothingToUndo) }
        guard accessibilityTrusted else { return .refuse(.needsPermission) }
        guard let recordPID, recordPID == frontmostPID else { return .refuse(.appChanged(nil)) }

        switch method {
        case .accessibility(let location, let text):
            guard focusedElementMatches, let currentValue,
                  let range = exactRange(of: text, at: location, in: currentValue) else {
                return .refuse(.textChanged)
            }
            return .removeText(range)
        case .accessibilityNormalized:
            return .refuse(.textChanged)
        case .keystroke:
            return .sendCommandZ
        }
    }

    /// The range only when the inserted text is still exactly there.
    static func exactRange(of text: String, at location: Int, in value: String) -> NSRange? {
        let nsValue = value as NSString
        let length = (text as NSString).length
        guard length > 0, location >= 0, location + length <= nsValue.length else { return nil }
        let range = NSRange(location: location, length: length)
        return nsValue.substring(with: range) == text ? range : nil
    }

    /// The field value with the insertion taken out.
    static func removing(_ range: NSRange, from value: String) -> String {
        (value as NSString).replacingCharacters(in: range, with: "")
    }
}

enum InsertionUndoPresenter {
    static var menuTitle: String { L10n.tr("Undo Last Dictation") }

    static func statusText(for outcome: InsertionUndoOutcome) -> String {
        switch outcome {
        case .removed:
            return L10n.tr("Removed your last dictation.")
        case .sentUndoKey:
            return L10n.tr("Pressed ⌘Z in the app. Check that it worked.")
        case .refused(let refusal):
            return refusalText(refusal)
        }
    }

    static func refusalText(_ refusal: InsertionUndoRefusal) -> String {
        switch refusal {
        case .nothingToUndo:
            return L10n.tr("Nothing to undo. YappYapp hasn't pasted anything yet.")
        case .appChanged(let name):
            if let name {
                return L10n.tr("Switch back to %@ to undo the last dictation.", name)
            }
            return L10n.tr("You switched apps. Switch back to undo the last dictation.")
        case .textChanged:
            return L10n.tr("The text changed since YappYapp pasted it. Press ⌘Z in the app to undo.")
        case .needsPermission:
            return L10n.tr("Undo needs the auto-paste permission. Allow it in Setup > Pasting.")
        case .busy:
            return L10n.tr("Finish this dictation first.")
        case .modifiersHeld:
            return L10n.tr("Let go of the shortcut keys, then undo again.")
        }
    }
}

/// Performs a planned undo against the live system. Never used by the
/// self-tests: they drive the planner with fake values.
@MainActor
final class InsertionUndoExecutor {
    private static let ansiZ: CGKeyCode = 0x06

    func undo(_ record: InsertionRecord?, target: NSRunningApplication?, accessibilityTrusted: Bool) -> InsertionUndoOutcome {
        guard let record else { return .refused(.nothingToUndo) }
        guard accessibilityTrusted else { return .refused(.needsPermission) }

        // From the menu bar or the popover, YappYapp may be in front. The
        // last external app is then the one to check, brought forward first.
        if let target, target.processIdentifier == record.processIdentifier, !target.isTerminated {
            activate(target)
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedMatches = false
        var currentValue: String?
        if let pid = frontmostPID, let element = record.element {
            if let focused = focusedElement(pid: pid), CFEqual(focused, element) {
                focusedMatches = true
                currentValue = value(of: element)
            }
        }

        let plan = InsertionUndoPlanner.plan(
            method: record.method,
            recordPID: record.processIdentifier,
            frontmostPID: frontmostPID,
            accessibilityTrusted: true,
            focusedElementMatches: focusedMatches,
            currentValue: currentValue
        )

        switch plan {
        case .removeText(let range):
            guard let element = record.element, let currentValue else { return .refused(.textChanged) }
            let newValue = InsertionUndoPlanner.removing(range, from: currentValue)
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success,
                  value(of: element) == newValue else {
                return .refused(.textChanged)
            }
            var caret = CFRange(location: range.location, length: 0)
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
            }
            return .removed
        case .sendCommandZ:
            return sendCommandZ() ? .sentUndoKey : .refused(.modifiersHeld)
        case .refuse(.appChanged):
            return .refused(.appChanged(record.applicationName))
        case .refuse(let refusal):
            return .refused(refusal)
        }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = ClipboardInjector.boundingTimeout(AXUIElementCreateApplication(pid))
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success else {
            return nil
        }
        return ClipboardInjector.axElement(fromAccessibilityValue: focusedValue).map(ClipboardInjector.boundingTimeout)
    }

    private func value(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func activate(_ application: NSRunningApplication) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier else { return }
        application.activate(options: [])
        let deadline = Date().addingTimeInterval(0.9)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        usleep(150_000)
    }

    /// Posts Cmd+Z on the key that types "z" on the current layout. Refuses
    /// while the user still holds a modifier (the undo shortcut itself), so
    /// the app never sees the wrong chord.
    private func sendCommandZ() -> Bool {
        guard waitForModifiersToClear() else { return false }
        let keyCodeCommand: CGKeyCode = 0x37
        var keyCodeZ = Self.ansiZ
        if let translate = KeyboardLayoutKeyCode.currentLayoutTranslator(commandHeld: true),
           let code = KeyboardLayoutKeyCode.keyCode(for: "z", translate: translate) {
            keyCodeZ = code
        }
        let source = CGEventSource(stateID: .combinedSessionState)

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true)
        commandDown?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        let zDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeZ, keyDown: true)
        zDown?.flags = .maskCommand
        zDown?.post(tap: .cghidEventTap)
        usleep(35_000)
        let zUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeZ, keyDown: false)
        zUp?.flags = .maskCommand
        zUp?.post(tap: .cghidEventTap)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)
        commandUp?.flags = []
        commandUp?.post(tap: .cghidEventTap)
        return true
    }

    private func waitForModifiersToClear() -> Bool {
        let interfering: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let deadline = Date().addingTimeInterval(0.8)
        usleep(100_000)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: interfering) {
                return true
            }
            usleep(20_000)
        }
        return NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: interfering)
    }
}
