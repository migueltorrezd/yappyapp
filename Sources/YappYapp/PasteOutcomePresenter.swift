import Foundation

struct PasteStatusSnapshot: Equatable {
    let phase: CapturePhase
    let statusText: String
}

enum PasteOutcomePresenter {
    /// The persistent "Auto-paste is off" banner is shown on every popover tab
    /// whenever macOS Accessibility is not trusted, independent of the
    /// pasteWhenFocusIsUnclear toggle (unlike the guided-setup row). TCC itself
    /// is invisible to the self-tests, so both popovers route their banner
    /// visibility through this single pure predicate and the test exercises it
    /// directly instead of restating the closure.
    static func showsAutoPasteOffBanner(accessibilityTrusted: Bool) -> Bool {
        !accessibilityTrusted
    }

    static func copiedStatus() -> PasteStatusSnapshot {
        PasteStatusSnapshot(phase: .copied, statusText: L10n.tr("Copied to the clipboard."))
    }

    static func accessibilityRequestStatus(isTrusted: Bool) -> String {
        isTrusted
            ? L10n.tr("Auto-paste is on.")
            : accessibilityRepairWaitingStatus()
    }

    static func accessibilityRepairWaitingStatus() -> String {
        L10n.tr("Waiting for macOS. If YappYapp is already on in Accessibility, remove it and add it again.")
    }

    static func accessibilityRepairTimedOutStatus() -> String {
        L10n.tr("Still not allowed. In System Settings > Privacy & Security > Accessibility, remove YappYapp, then add it again.")
    }

    // STALE-TCC-DETECT: deterministic copy for the one-click reset and re-grant.
    static var staleResetButtonTitle: String { L10n.tr("Still not pasting? Reset the permission") }

    static func staleResetStatus(didReset: Bool) -> String {
        didReset
            ? L10n.tr("Old permission cleared. Allow YappYapp when macOS asks, then dictate again.")
            : L10n.tr("Couldn't clear it. In System Settings > Privacy & Security > Accessibility, remove YappYapp, then add it again.")
    }

    /// `restoresClipboard` says whether a best-effort paste will put the old
    /// clipboard back. When it will, "press Cmd+V" would paste the old content,
    /// so the advice points to COPY instead (YA-15).
    static func status(
        for outcome: PasteOutcome,
        elapsedLabel: String? = nil,
        restoresClipboard: Bool = false
    ) -> PasteStatusSnapshot {
        switch outcome {
        case .pasted:
            let statusText = elapsedLabel.map {
                L10n.tr("Done in %@. Pasted at your cursor.", $0)
            } ?? L10n.tr("Pasted at your cursor.")
            return PasteStatusSnapshot(phase: .pasted, statusText: statusText)
        case .pastedBestEffort:
            // HONEST-PASTE-CONFIRM: we triggered a paste but cannot confirm it
            // landed. Tell the truth and give the user a fallback. YA-03: its
            // own phase, so the UI shows SENT? and never a confirmed checkmark.
            let fallback = restoresClipboard
                ? L10n.tr("Nothing there? Press COPY in HISTORY.")
                : L10n.tr("Nothing there? Press ⌘V.")
            let statusText = elapsedLabel.map {
                L10n.tr("Done in %@. Pasted, but the app didn't confirm. %@", $0, fallback)
            } ?? L10n.tr("Pasted, but the app didn't confirm. %@", fallback)
            return PasteStatusSnapshot(phase: .sentUnconfirmed, statusText: statusText)
        case .copiedOnly(let reason):
            // The legacy secure-input copy-only case copies nothing either.
            let copied = reason != .secureInputActive
            let headline = copied ? copiedOnlyHeadline : notPastedHeadline
            return PasteStatusSnapshot(
                phase: .notDelivered(headline: headline, reason: hudReason(for: reason, copied: copied)),
                statusText: statusText(for: reason)
            )
        case .withheld(let reason):
            // HONEST-PASTE-CONFIRM: nothing was copied, so the .copiedOnly copy
            // (which for every reason except secureInputActive claims the transcript
            // is "on the clipboard, press Cmd+V") would be a lie here. Use dedicated
            // withheld wording that never promises a clipboard paste. YA-03:
            // yellow NOT PASTED, never a confirmed-paste checkmark.
            return PasteStatusSnapshot(
                phase: .notDelivered(headline: notPastedHeadline, reason: hudReason(for: reason, copied: false)),
                statusText: withheldStatusText(for: reason)
            )
        }
    }

    static var copiedOnlyHeadline: String { L10n.tr("COPIED ONLY") }
    static var notPastedHeadline: String { L10n.tr("NOT PASTED") }

    /// YA-03: the short reason the HUD prints next to COPIED ONLY / NOT PASTED,
    /// with the one recovery: ⌘V when the text is on the clipboard, TEXT KEPT
    /// (it waits in HISTORY) when it was kept off it.
    static func hudReason(for reason: ClipboardPasteBlockReason, copied: Bool) -> String {
        copied
            ? L10n.tr("%@ · ⌘V TO PASTE", hudCause(for: reason))
            : L10n.tr("%@ · TEXT KEPT", hudCause(for: reason))
    }

    static func hudCause(for reason: ClipboardPasteBlockReason) -> String {
        switch reason {
        case .accessibilityNotTrusted: L10n.tr("AUTO-PASTE NOT ALLOWED")
        case .secureInputActive: L10n.tr("SECURE INPUT")
        case .focusUnclear: L10n.tr("NO TEXT FIELD")
        case .modifiersHeld: L10n.tr("KEY STILL DOWN")
        case .autoPasteOff: L10n.tr("AUTO-PASTE OFF")
        case .newerDictation: L10n.tr("NEWER DICTATION")
        }
    }

    /// YA-61: names the app holding secure input when it is known.
    static func secureInputHolderSuffix(_ holder: String?) -> String {
        guard let holder, !holder.isEmpty else { return "" }
        return " " + L10n.tr("%@ turned it on.", holder)
    }

    /// YA-03: how long an outcome stays on the HUD. Problems stay long enough
    /// to read; a confirmed paste gets out of the way.
    static func holdSeconds(for phase: CapturePhase, hasPetNews: Bool = false) -> TimeInterval {
        let base: TimeInterval
        switch phase {
        case .pasted, .copied: base = 1.4
        case .sentUnconfirmed: base = 2.5
        case .notDelivered, .error: base = 5.0
        case .canceled: base = CancelUndoBuffer.window
        case .idle, .recording, .transcribing: base = 1.4
        }
        return hasPetNews ? max(base, 3.0) : base
    }

    /// YA-03: a readable one-line label for an error, instead of "ERR".
    /// L10N: the message may be in any app language (or the system's), so
    /// each class lists its words in English, French, Spanish and Dutch.
    static func errorShortLabel(_ message: String) -> String {
        let lowered = message.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lowered.contains($0) } }
        if has([
            "timed out", "took too long", "délai dépassé", "trop de temps", "tiempo de espera", "tardó demasiado",
            "time-out", "duurde te lang"
        ]) { return L10n.tr("TIMED OUT") }
        if has([
            "silence", "no audio", "heard nothing", "heard no words", "aucun signal audio", "rien entendu", "aucun mot",
            "silencio", "sin señal de audio", "no se oyó nada", "ninguna palabra", "stilte", "geen audiosignaal",
            "niets gehoord", "geen woorden"
        ]) {
            return L10n.tr("HEARD NOTHING")
        }
        if has([
            "microphone", "mic", "audio device", "input device", "micro", "périphérique", "micrófono",
            "dispositivo de audio", "dispositivo de entrada", "microfoon", "audioapparaat", "invoerapparaat"
        ]) {
            return L10n.tr("MIC TROUBLE")
        }
        if has(["download", "télécharg", "descarg", "descárg"]) { return L10n.tr("DOWNLOAD NEEDED") }
        if has(["model", "modèle", "modelo"]) { return L10n.tr("MODEL TROUBLE") }
        if has(["binary", "whisper", "binaire", "binario"]) { return L10n.tr("WHISPER TROUBLE") }
        return genericErrorLabel
    }

    /// The label for an error no class matches; the HUD trailing box uses it too.
    static var genericErrorLabel: String { L10n.tr("DIDN'T WORK") }

    /// HONEST-PASTE-CONFIRM: wording for outcomes where NOTHING was copied. Unlike
    /// statusText(for:), this never tells the user to press Cmd+V, because the
    /// transcript is not on the clipboard.
    static func withheldStatusText(for reason: ClipboardPasteBlockReason) -> String {
        switch reason {
        case .secureInputActive:
            return L10n.tr("Secure input is on (a password field or a secure terminal). Your text is safe in HISTORY: press COPY.")
        case .accessibilityNotTrusted:
            return L10n.tr("Auto-paste isn't allowed yet. Your text is in HISTORY: press COPY.")
        case .focusUnclear:
            return L10n.tr("No text field had focus. Your text is in HISTORY: press COPY.")
        case .modifiersHeld:
            return L10n.tr("A key was still down. Your text is in HISTORY: press COPY.")
        case .autoPasteOff:
            return L10n.tr("Auto-paste is off in Setup. Your text is in HISTORY: press COPY.")
        case .newerDictation:
            return L10n.tr("A newer dictation started first. This one is in HISTORY.")
        }
    }

    static func statusText(for reason: ClipboardPasteBlockReason) -> String {
        switch reason {
        case .accessibilityNotTrusted:
            return L10n.tr("Auto-paste isn't allowed yet. Press ⌘V to paste.")
        case .secureInputActive:
            return L10n.tr("Secure input is on (a password field or a secure terminal). Your text is safe in HISTORY: press COPY.")
        case .focusUnclear:
            return L10n.tr("No text field had focus. Press ⌘V where you want it.")
        case .modifiersHeld:
            return L10n.tr("A key was still down. Press ⌘V to paste.")
        case .autoPasteOff:
            return L10n.tr("Copied. Auto-paste is off, so press ⌘V to paste.")
        case .newerDictation:
            return L10n.tr("A newer dictation started. This one is also in HISTORY.")
        }
    }
}
