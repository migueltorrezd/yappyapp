import AppKit
import ApplicationServices
import Carbon
import Foundation

// LEARN-FROM-FIXES: the live half. After a paste, it re-reads ONLY the field
// YappYapp just wrote into, for at most 20 seconds, with a light poll on the
// main thread (every Accessibility call is bounded by the 0.35 s messaging
// timeout). It stops when the window ends, focus leaves that field, another
// app comes to the front, the next dictation starts, secure input turns on,
// or the text around the pasted stretch changes. Then it hands the pasted
// text and how that stretch reads now to the pure rules in AutoLearn.swift.
// Nothing it reads is logged or written anywhere; only a learned word is.
//
// Skipped: terminals, secure text fields, secure input, fields whose value
// cannot be read, and Accessibility writes the field reformatted (the exact
// range is unknown there).

@MainActor
final class AutoLearnWatcher {
    static let window: TimeInterval = 20
    static let pollInterval: TimeInterval = 0.75
    /// A Cmd+V paste lands a beat later; look for it this many times.
    static let locateAttempts = 3

    /// Called once per watch when the pasted stretch changed.
    var onSettled: (_ inserted: String, _ edited: String) -> Void = { _, _ in }

    private struct Session {
        let pid: pid_t
        var element: AXUIElement?
        var original: String
        var location: Int
        let inserted: String
        let startedAt: Date
        var latest: String?
        var locateAttemptsLeft: Int
    }

    private var session: Session?
    private var timer: Timer?

    var isWatching: Bool { session != nil }

    /// Starts watching the insertion `record` describes. Anything that
    /// cannot be watched safely is skipped without a trace.
    func begin(record: InsertionRecord?, pastedText: String) {
        settleNow()
        guard let record, let pid = record.processIdentifier, !pastedText.isEmpty,
              !IsSecureEventInputEnabled() else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard ClipboardInjector.targetKind(for: bundleID) != .terminal else { return }

        switch record.method {
        case .accessibility(let location, let text):
            guard let element = record.element, Self.isReadableField(element),
                  let value = Self.value(of: element),
                  InsertionUndoPlanner.exactRange(of: text, at: location, in: value) != nil else { return }
            session = Session(
                pid: pid, element: element, original: value, location: location, inserted: text,
                startedAt: Date(), latest: nil, locateAttemptsLeft: 0
            )
        case .keystroke:
            session = Session(
                pid: pid, element: nil, original: "", location: 0, inserted: pastedText,
                startedAt: Date(), latest: nil, locateAttemptsLeft: Self.locateAttempts
            )
        case .accessibilityNormalized:
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The next dictation started (or the app is quitting): judge what the
    /// user changed so far and stop.
    func settleNow() {
        finish()
    }

    /// Stops without learning anything.
    func cancel() {
        timer?.invalidate()
        timer = nil
        session = nil
    }

    private func tick() {
        guard var current = session else { return cancel() }
        if Date().timeIntervalSince(current.startedAt) > Self.window || IsSecureEventInputEnabled() {
            return finish()
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
              let focused = Self.focusedElement(pid: current.pid) else {
            return finish()
        }

        // Cmd+V: find the field and the pasted stretch once it has landed.
        if current.element == nil {
            guard Self.isReadableField(focused), let value = Self.value(of: focused) else {
                return giveUpLocatingOrRetry(&current)
            }
            guard let location = AutoLearnRegion.locate(current.inserted, in: value, caret: Self.caret(of: focused)) else {
                return giveUpLocatingOrRetry(&current)
            }
            current.element = focused
            current.original = value
            current.location = location
            session = current
            return
        }

        guard let element = current.element, CFEqual(focused, element), let value = Self.value(of: element) else {
            return finish()
        }
        guard let edited = AutoLearnRegion.edited(
            original: current.original,
            location: current.location,
            length: (current.inserted as NSString).length,
            current: value
        ), (edited as NSString).length <= (current.inserted as NSString).length * 4 + 400 else {
            return finish()
        }
        current.latest = edited
        session = current
    }

    private func giveUpLocatingOrRetry(_ current: inout Session) {
        current.locateAttemptsLeft -= 1
        if current.locateAttemptsLeft <= 0 {
            cancel()
        } else {
            session = current
        }
    }

    private func finish() {
        let ended = session
        cancel()
        guard let ended, let latest = ended.latest, latest != ended.inserted else { return }
        onSettled(ended.inserted, latest)
    }

    // MARK: - Accessibility reads

    /// A text field whose value can be read and that is not a password field.
    static func isReadableField(_ element: AXUIElement) -> Bool {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
               let name = raw as? String, name == (kAXSecureTextFieldSubrole as String) || name.contains("Secure") {
                return false
            }
        }
        return value(of: element) != nil
    }

    static func value(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func caret(of element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success else {
            return nil
        }
        let range = ClipboardInjector.selectedTextRange(fromAccessibilityValue: raw, fallbackLocation: -1)
        return range.location >= 0 ? range.location + range.length : nil
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = ClipboardInjector.boundingTimeout(AXUIElementCreateApplication(pid))
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw) == .success else {
            return nil
        }
        return ClipboardInjector.axElement(fromAccessibilityValue: raw).map(ClipboardInjector.boundingTimeout)
    }
}
