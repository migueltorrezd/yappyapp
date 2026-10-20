import Foundation

// DELIVERY-TRAIL: the last few deliveries, kept in memory so a paste that did
// not land (Ghostty + a terminal multiplexer, a web view, a stuck modifier) can be diagnosed
// from the Help support report. Never the transcript, never a window title,
// never written to disk: bundle ids, the route taken and the outcome only.

/// How the target app was brought forward before the paste.
enum DeliveryActivation: String, Equatable, Sendable {
    /// No target app was known.
    case none
    /// The target was already in front, so it was left alone.
    case alreadyFrontmost
    /// The target was activated and came to the front in time.
    case activated
    /// The target was activated but another app was still in front.
    case notFrontmost
}

/// What the clipboard layer did with one transcript, minus the text.
struct DeliveryAttempt: Equatable, Sendable {
    var decision: String
    var activation: DeliveryActivation
    /// Whether the app in front right after a synthetic Cmd+V was the target.
    /// nil when no keystroke was posted or no target was known.
    var frontmostMatchedTarget: Bool?
    /// The previous clipboard comes back a few seconds after the paste.
    var restoresClipboard: Bool
    /// FOCUS-AT-DELIVERY: who held the keyboard right before the text went
    /// in, so a paste that landed nowhere can be explained from the report.
    var focus: DeliveryFocusReport? = nil
}

/// Which process owns something that matters for a paste: the app the text
/// is meant for, YappYapp itself, another app, or nobody AX could see.
enum FocusOwner: String, Equatable, Sendable {
    case target
    case yappyapp
    case other
    case unknown

    /// Pure: classify a pid against the delivery target and our own pid.
    static func classify(pid: pid_t?, targetPID: pid_t?, ownPID: pid_t) -> FocusOwner {
        guard let pid else { return .unknown }
        if pid == ownPID { return .yappyapp }
        if let targetPID, pid == targetPID { return .target }
        return .other
    }
}

/// The decisive focus facts at the moment of a paste, without any text or
/// window title. Collected by the clipboard layer after activation.
struct DeliveryFocusReport: Equatable, Sendable {
    /// YappYapp was the active app (a click on one of its windows, the
    /// popover or the control window).
    var yappyappActive: Bool
    /// One of YappYapp's windows was key.
    var yappyappKeyWindow: Bool
    /// The app macOS sends keystrokes to (system-wide AXFocusedApplication).
    var focusedApp: FocusOwner
    /// Bundle id of that app when it is neither the target nor YappYapp.
    var focusedAppBundle: String?
    /// The owner of the system-wide focused element.
    var focusedElement: FocusOwner
}

struct DeliveryTrailEntry: Equatable, Sendable {
    let date: Date
    let bundleIdentifier: String?
    let targetKind: ClipboardPasteTargetKind
    let decision: String
    let outcome: String
    let activation: DeliveryActivation
    let frontmostMatchedTarget: Bool?
    let restoresClipboard: Bool
    /// Name of the app holding secure input when the paste was withheld.
    let secureInputHolder: String?
    /// FOCUS-AT-DELIVERY: who held the keyboard when the text went in.
    var focus: DeliveryFocusReport? = nil
}

/// Ring buffer of the newest deliveries. Pure, so tests pin its rules.
struct DeliveryTrail: Equatable, Sendable {
    static let capacity = 20

    private(set) var entries: [DeliveryTrailEntry] = []

    /// Newest last; the oldest falls off past `capacity`.
    mutating func record(_ entry: DeliveryTrailEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    static func outcomeLabel(_ outcome: PasteOutcome) -> String {
        switch outcome {
        case .pasted: "pasted"
        case .pastedBestEffort: "pastedBestEffort"
        case .copiedOnly(let reason): "copiedOnly(\(reasonLabel(reason)))"
        case .withheld(let reason): "withheld(\(reasonLabel(reason)))"
        }
    }

    static func reasonLabel(_ reason: ClipboardPasteBlockReason) -> String {
        switch reason {
        case .accessibilityNotTrusted: "accessibilityNotTrusted"
        case .secureInputActive: "secureInputActive"
        case .focusUnclear: "focusUnclear"
        case .modifiersHeld: "modifiersHeld"
        case .autoPasteOff: "autoPasteOff"
        case .newerDictation: "newerDictation"
        }
    }

    static func kindLabel(_ kind: ClipboardPasteTargetKind) -> String {
        switch kind {
        case .native: "native"
        case .browser: "browser"
        case .terminal: "terminal"
        case .webViewApp: "webViewApp"
        }
    }

    /// FOCUS-AT-DELIVERY: `yappyappActive=no keyWindow=none focusedApp=target
    /// focusedElement=target`. A focused app outside the target names its
    /// bundle id, never a window title.
    static func focusParts(_ focus: DeliveryFocusReport) -> [String] {
        var focusedApp = focus.focusedApp.rawValue
        if focus.focusedApp == .other, let bundle = focus.focusedAppBundle {
            focusedApp += "(\(bundle))"
        }
        return [
            "yappyappActive=\(focus.yappyappActive ? "yes" : "no")",
            "keyWindow=\(focus.yappyappKeyWindow ? "yappyapp" : "none")",
            "focusedApp=\(focusedApp)",
            "focusedElement=\(focus.focusedElement.rawValue)"
        ]
    }

    /// One support-report line per delivery, oldest first. App names come
    /// only from the secure-input holder, which macOS reports as an app.
    func reportLines() -> [String] {
        entries.map { entry in
            var parts = [
                SupportReport.isoTimestamp(entry.date),
                entry.bundleIdentifier ?? "no-target",
                Self.kindLabel(entry.targetKind),
                "decision=\(entry.decision)",
                "outcome=\(entry.outcome)",
                "activation=\(entry.activation.rawValue)"
            ]
            if let matched = entry.frontmostMatchedTarget {
                parts.append("frontmostAfterPaste=\(matched ? "target" : "other app")")
            }
            if entry.restoresClipboard {
                parts.append("clipboardRestore=on")
            }
            if let holder = entry.secureInputHolder {
                parts.append("secureInputHolder=\(holder)")
            }
            if let focus = entry.focus {
                parts.append(contentsOf: Self.focusParts(focus))
            }
            return "- " + parts.joined(separator: " ")
        }
    }
}
