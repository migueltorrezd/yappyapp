import Foundation

// SHORTCUTS: paste-last. Re-delivers the most recent dictation at the cursor
// through the normal paste path. The text comes only from the in-memory
// transcript history; nothing is ever read from or written to disk.

enum PasteLastDecision: Equatable {
    case paste(String)
    case nothingYet
    case busyRecording
    case busyTranscribing
    case busyPasting

    var statusText: String? {
        switch self {
        case .paste: nil
        case .nothingYet: L10n.tr("Nothing to paste yet. Dictate something first.")
        case .busyRecording: L10n.tr("Finish this dictation first.")
        case .busyTranscribing: L10n.tr("Still transcribing. Try again in a moment.")
        case .busyPasting: L10n.tr("Still pasting the last dictation. One moment.")
        }
    }
}

@MainActor
final class PasteLastController {
    private(set) var isPasting = false

    nonisolated static func decide(
        history: [TranscriptEntry],
        phase: CapturePhase,
        pasteInFlight: Bool
    ) -> PasteLastDecision {
        if pasteInFlight { return .busyPasting }
        switch phase {
        case .recording: return .busyRecording
        case .transcribing: return .busyTranscribing
        default: break
        }
        guard let text = history.first?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingYet
        }
        return .paste(text)
    }

    /// Runs one paste-last. `deliver` is the app's existing paste path. The
    /// in-flight flag drops a re-entrant press while the paste spins the run loop.
    func run(
        history: [TranscriptEntry],
        phase: CapturePhase,
        otherPasteInFlight: Bool,
        deliver: (String) -> PasteStatusSnapshot,
        report: (PasteLastDecision, PasteStatusSnapshot?) -> Void
    ) {
        let decision = Self.decide(
            history: history,
            phase: phase,
            pasteInFlight: otherPasteInFlight || isPasting
        )
        guard case .paste(let text) = decision else {
            report(decision, nil)
            return
        }
        isPasting = true
        let snapshot = deliver(text)
        isPasting = false
        report(decision, snapshot)
    }
}

/// Copy that depends on the active shortcut, so a rebound user never reads
/// "⌥ space" anywhere.
enum ShortcutCopy {
    static let defaultInline = "⌥ space"

    /// Inline name of whatever starts dictation, e.g. "⌥ space" or "right ⌥".
    static func dictationInline(_ settings: ShortcutSettings) -> String? {
        if let chord = settings.chord(for: .toggleDictation) {
            return ShortcutKeyNames.inlineLabel(for: chord)
        }
        if let hold = settings.modifierHold {
            return hold.spokenName.lowercased()
        }
        return nil
    }

    /// `cancelEnabled` follows the YA-19 setting; the cancel key is only
    /// named while it works.
    static func listeningStatus(_ settings: ShortcutSettings, cancelEnabled: Bool = true) -> String {
        // Key names read as in prose: "Esc", while chords keep "⌥ space".
        let cancel = cancelEnabled ? settings.chord(for: .cancel).map { chord in
            chord == .escape ? "Esc" : ShortcutKeyNames.inlineLabel(for: chord)
        } : nil
        let cancelTail = cancel.map { L10n.tr(", %@ to cancel.", $0) } ?? "."
        guard let trigger = dictationInline(settings) else {
            return L10n.tr("Listening. Click stop when you're done") + cancelTail
        }
        switch settings.mode {
        case .toggle:
            return L10n.tr("Listening. Press %@ to stop", trigger) + cancelTail
        case .hold:
            return L10n.tr("Listening. Release %@ to stop", trigger) + cancelTail
        case .hybrid:
            return L10n.tr("Listening. Release or press %@ to stop", trigger) + cancelTail
        }
    }

    static func registrationFailure(_ settings: ShortcutSettings, failed: [ShortcutAction]) -> String? {
        guard !failed.isEmpty else { return nil }
        if failed.contains(.toggleDictation), let chord = settings.chord(for: .toggleDictation) {
            return L10n.tr("Couldn't use %@. Another app may have it. Pick another in Setup > Dictation.", ShortcutKeyNames.inlineLabel(for: chord))
        }
        let names = failed.map { $0.title.lowercased() }.joined(separator: ", ")
        return L10n.tr("Couldn't use the %@ shortcut. Pick another in Setup > Dictation.", names)
    }

    static func tooltip(_ settings: ShortcutSettings) -> String {
        guard let trigger = dictationInline(settings) else {
            return L10n.tr("YappYapp (right-click for menu)")
        }
        return L10n.tr("YappYapp (%@ to dictate, right-click for menu)", trigger)
    }

    /// Rewrites the shipped "⌥ space" wording in idle prompts to the active
    /// shortcut. Leaves the text untouched for the default binding.
    static func personalize(_ text: String, _ settings: ShortcutSettings) -> String {
        guard let trigger = dictationInline(settings), trigger != defaultInline else {
            return text
        }
        var result = text.replacingOccurrences(of: defaultInline, with: trigger)
        if let chord = settings.chord(for: .toggleDictation) {
            result = result.replacingOccurrences(of: "Option Space", with: ShortcutKeyNames.spokenLabel(for: chord))
        } else if let hold = settings.modifierHold {
            result = result.replacingOccurrences(of: "Option Space", with: hold.spokenName)
        }
        return result
    }

    /// YA-05: retry only has something to run after a failed dictation.
    static func retryUnavailable() -> String {
        L10n.tr("Nothing to retry yet. Dictate something first.")
    }

    /// Status line when the one-key trigger is chosen. Global key monitors
    /// only see other apps' keys while YappYapp holds Accessibility.
    static func modifierHoldPermission(trusted: Bool) -> String {
        trusted
            ? L10n.tr("Uses the auto-paste permission, already allowed.")
            : L10n.tr("Needs auto-paste. Allow it under Pasting.")
    }

    /// VoiceOver summary of the active shortcuts, e.g. "Option Space starts
    /// dictation anywhere. Press to start, press again to stop."
    static func spokenSummary(_ settings: ShortcutSettings) -> String {
        var triggers: [String] = []
        if let chord = settings.chord(for: .toggleDictation) {
            triggers.append(ShortcutKeyNames.spokenLabel(for: chord))
        }
        if let hold = settings.modifierHold {
            triggers.append(hold.spokenName)
        }
        var parts: [String] = []
        if triggers.isEmpty {
            parts.append(L10n.tr("No dictation shortcut set."))
        } else {
            parts.append(L10n.tr("%@ starts dictation anywhere. %@", triggers.joined(separator: L10n.tr(" or ")), settings.mode.explanation))
        }
        if let paste = settings.chord(for: .pasteLast) {
            parts.append(L10n.tr("%@ pastes the last dictation.", ShortcutKeyNames.spokenLabel(for: paste)))
        }
        return parts.joined(separator: " ")
    }

    /// Menu title suffix for a trigger the menu cannot show as a key
    /// equivalent (the one-key trigger), e.g. "Start Dictation (Right Option)".
    static func menuTitle(_ base: String, settings: ShortcutSettings) -> String {
        guard settings.chord(for: .toggleDictation) == nil, let hold = settings.modifierHold else {
            return base
        }
        return "\(base) (\(hold.spokenName))"
    }
}

/// YA-72 with SHORTCUTS: dictation counts as unreachable from the keyboard
/// only when its chord failed to register and no one-key trigger stands in.
enum HotkeyAvailability {
    static func isUnavailable(settings: ShortcutSettings, failed: [ShortcutAction]) -> Bool {
        failed.contains(.toggleDictation) && settings.modifierHold == nil
    }
}
