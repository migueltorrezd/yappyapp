import Foundation

/// YA-02: what happens to a finished transcript.
enum DeliveryRoute: Equatable {
    /// The session is still current and nothing else is pasting: paste it.
    case deliver
    /// Another delivery is mid-paste (its Cmd+V spins the run loop). Wait for
    /// it, then route again, so transcripts land in order.
    case queueBehindPaste
    /// A newer dictation became current. Never drop it: copy and notify.
    case copySuperseded
}

/// YA-18: where a finished dictation is pasted. The text goes where the user
/// is: the app in front at delivery time, or, when YappYapp itself is in
/// front, the app that was in front when the recording stopped.
enum PasteTargetResolution: Equatable {
    /// Paste into the app in front right now.
    case current
    /// YappYapp itself is in front; use the target captured at the stop.
    case stopTarget
}

enum PasteTargetPolicy {
    /// `currentPID` is nil when YappYapp itself is frontmost at delivery.
    static func resolve(currentPID: pid_t?) -> PasteTargetResolution {
        currentPID == nil ? .stopTarget : .current
    }
}

/// PROFILES / YA-18: which app a dictation belongs to. The app in front when
/// the recording stops wins; the start app is used only when no external app
/// could be found at the stop.
enum DictationTargetPolicy {
    static func sessionTarget(stopTarget: PasteTarget?, startTarget: PasteTarget?) -> PasteTarget? {
        stopTarget ?? startTarget
    }
}

/// FOCUS-AT-DELIVERY: the rules for where a finished dictation is typed.
///
/// The text goes to the element focused at delivery, in the app in front at
/// delivery. "In front" means more than NSWorkspace's frontmost app: macOS
/// can report an app as frontmost while its window is not key (Ghostty then
/// draws a hollow cursor and drops a Cmd+V), or while YappYapp itself holds
/// the keyboard. So activation is skipped only when the target is in front
/// AND owns the keyboard AND no YappYapp window is in the way.
enum DeliveryFocusPolicy {
    struct Facts: Equatable, Sendable {
        var targetPID: pid_t?
        /// NSWorkspace.frontmostApplication.
        var frontmostPID: pid_t?
        /// System-wide AXFocusedApplication: who gets keystrokes. nil when
        /// AX could not say.
        var focusedAppPID: pid_t?
        var yappyappActive: Bool
        var yappyappHasKeyWindow: Bool
    }

    /// Whether the target must be brought forward (and its window made key)
    /// before the paste.
    static func needsActivation(_ facts: Facts) -> Bool {
        guard let target = facts.targetPID else { return false }
        if facts.yappyappActive || facts.yappyappHasKeyWindow { return true }
        guard facts.frontmostPID == target else { return true }
        // In front per NSWorkspace. When AX knows who gets the keyboard, it
        // must be the target too; unknown keeps the old, gentler behavior
        // (re-activating reshuffles Ghostty's native tabs).
        if let focused = facts.focusedAppPID, focused != target { return true }
        return false
    }

    /// Whether activation reached the state a paste needs.
    static func isReady(_ facts: Facts) -> Bool {
        !needsActivation(facts)
    }

    /// Where an AX insert candidate came from.
    enum ElementSource: Equatable, Sendable {
        /// Captured earlier (at the stop, or by the activation observer).
        case captured
        /// The target app's focused element, read again at delivery.
        case targetFocused
        /// The system-wide focused element, read at delivery.
        case systemFocused
    }

    /// Whether an element may receive an AX insert. A captured element is
    /// never written into: the user may have clicked another field since.
    /// The system-wide element counts only when it belongs to the target
    /// (and never when it is YappYapp's own).
    static func admits(_ source: ElementSource, elementPID: pid_t?, targetPID: pid_t?, ownPID: pid_t) -> Bool {
        switch source {
        case .captured:
            return false
        case .targetFocused:
            return targetPID != nil && elementPID != ownPID
        case .systemFocused:
            guard let elementPID, elementPID != ownPID else { return false }
            guard let targetPID else { return true }
            return elementPID == targetPID
        }
    }
}

/// A local notification about a dictation that did not land.
struct DeliveryNotice: Equatable {
    let title: String
    let body: String
    /// Text the COPY action puts on the clipboard. Held in memory only.
    let copyText: String?
    /// The COPY action marks the clipboard item concealed (YA-14).
    let copyIsSensitive: Bool
}

/// Missing feature 3: tell the user when a dictation fails or does not land
/// while the controls are closed. No transcript text in the notification
/// unless the user turned on "show text in notifications".
enum DeliveryNotificationPolicy {
    static let previewLimit = 120

    static func shouldNotify(for outcome: PasteOutcome, controlsVisible: Bool) -> Bool {
        guard !controlsVisible else { return false }
        switch outcome {
        case .pasted, .pastedBestEffort:
            return false
        case .copiedOnly(.autoPasteOff):
            // Copy-only is the mode the user picked; a banner each time is noise.
            return false
        case .copiedOnly, .withheld:
            return true
        }
    }

    static func notice(for outcome: PasteOutcome, transcript: String, showText: Bool) -> DeliveryNotice {
        let title: String
        let reasonLine: String
        var sensitive = false

        switch outcome {
        case .pasted:
            title = L10n.tr("Dictation pasted")
            reasonLine = L10n.tr("Pasted at your cursor.")
        case .pastedBestEffort:
            title = L10n.tr("Dictation pasted")
            reasonLine = L10n.tr("The app didn't confirm it. Check that it's there.")
        case .copiedOnly(let reason):
            if reason == .secureInputActive {
                title = L10n.tr("Dictation not pasted")
                reasonLine = L10n.tr("Secure input was on, so it wasn't copied. Press Copy to take your text.")
                sensitive = true
            } else {
                title = L10n.tr("Copied, not pasted")
                reasonLine = copiedReasonLine(for: reason)
            }
        case .withheld(let reason):
            title = L10n.tr("Dictation not pasted")
            reasonLine = reason == .secureInputActive
                ? L10n.tr("Secure input was on, so it wasn't copied. Press Copy to take your text.")
                : L10n.tr("Not pasted. Press Copy to take your text.")
            sensitive = true
        }

        return DeliveryNotice(
            title: title,
            body: body(reasonLine, transcript: transcript, showText: showText),
            copyText: transcript.isEmpty ? nil : transcript,
            copyIsSensitive: sensitive
        )
    }

    /// `audioKept` says the failed audio waits for a retry (YA-05).
    static func failureNotice(message: String, audioKept: Bool = false) -> DeliveryNotice {
        let label = PasteOutcomePresenter.errorShortLabel(message)
        let body: String
        if label == PasteOutcomePresenter.genericErrorLabel {
            // The title already says it didn't work; don't repeat it.
            body = audioKept ? L10n.tr("Your audio is kept. Open YappYapp to retry.") : L10n.tr("Open YappYapp for details.")
        } else {
            let reason = sentenceCase(label)
            body = audioKept
                ? L10n.tr("%@. Your audio is kept. Open YappYapp to retry.", reason)
                : L10n.tr("%@. Open YappYapp for details.", reason)
        }
        return DeliveryNotice(
            title: L10n.tr("Dictation didn't work"),
            body: body,
            copyText: nil,
            copyIsSensitive: false
        )
    }

    /// "MIC TROUBLE" becomes "Mic trouble": only the first letter stays
    /// capital, unlike `.capitalized`, which made "Timed Out".
    static func sentenceCase(_ label: String) -> String {
        let lowered = label.lowercased(with: L10n.locale)
        guard let first = lowered.first else { return lowered }
        return String(first).uppercased(with: L10n.locale) + lowered.dropFirst()
    }

    private static func copiedReasonLine(for reason: ClipboardPasteBlockReason) -> String {
        switch reason {
        case .newerDictation:
            return L10n.tr("A newer dictation started, so this one is copied.")
        case .focusUnclear:
            return L10n.tr("No text field had focus. Press ⌘V where you want it.")
        case .accessibilityNotTrusted:
            return L10n.tr("Auto-paste isn't allowed yet. Press ⌘V to paste.")
        case .modifiersHeld:
            return L10n.tr("A key was still down. Press ⌘V to paste.")
        case .autoPasteOff:
            return L10n.tr("Auto-paste is off. Press ⌘V to paste.")
        case .secureInputActive:
            // Unreachable: notice(for:) handles secure input before this.
            return L10n.tr("Secure input was on, so it wasn't copied. Press Copy to take your text.")
        }
    }

    private static func body(_ reasonLine: String, transcript: String, showText: Bool) -> String {
        guard showText, !transcript.isEmpty else { return reasonLine }
        let preview = transcript.count > previewLimit
            ? String(transcript.prefix(previewLimit)) + "…"
            : transcript
        return "\(reasonLine)\n\"\(preview)\""
    }
}

/// YA-03: the pet celebrates a confirmed paste only.
enum PetCelebrationPolicy {
    static func celebrates(_ phase: CapturePhase) -> Bool {
        phase == .pasted
    }
}

/// HUD wording for the recording and outcome states (YA-03, YA-19, YA-54).
enum HUDPresenter {
    static let countdownWindow = 10

    /// The effective time limit, matching the auto-stop scheduler's floor.
    static func limitSeconds(for config: AppConfig) -> Int {
        Int(max(10, config.maxRecordingSeconds))
    }

    /// YA-54: seconds left once inside the last ten, otherwise nil.
    static func countdown(elapsed: Int, limit: Int) -> Int? {
        let remaining = limit - elapsed
        guard remaining > 0, remaining <= countdownWindow else { return nil }
        return remaining
    }

    /// The indicator's note or reason. The compact bar draws no words, so
    /// this is spoken by VoiceOver as the indicator's value.
    /// `retryShown`: RETRY is offered, so the caption carries the error
    /// itself. `pastedIn` is how long a confirmed paste took ("0.8s").
    static func caption(
        for phase: CapturePhase,
        escCancels: Bool,
        countdown: Int?,
        note: String?,
        retryShown: Bool = false,
        pastedIn: String? = nil
    ) -> String? {
        switch phase {
        case .recording:
            if let countdown { return L10n.tr("AUTO-STOP IN %@S", "\(countdown)") }
            return escCancels ? L10n.tr("ESC TO CANCEL") : nil
        case .transcribing:
            return note
        case .pasted:
            // A cleanup note (AS SPOKEN · ...) matters more than the speed.
            return note ?? pastedIn.map { L10n.tr("DONE IN %@", $0.uppercased(with: L10n.locale)) }
        case .sentUnconfirmed:
            return L10n.tr("CHECK THE APP")
        case .notDelivered(_, let reason):
            return reason
        case .canceled:
            return L10n.tr("CANCELED · KEEP IT? 5S")
        case .error(let message):
            let label = PasteOutcomePresenter.errorShortLabel(message)
            // The trailing box already reads DIDN'T WORK; don't say it twice.
            if label == PasteOutcomePresenter.genericErrorLabel, !retryShown { return nil }
            return label
        case .copied, .idle:
            return nil
        }
    }

    /// The state word VoiceOver reads for the indicator.
    /// One wording for every phase, shared with YA-75's HUD labels.
    static func trailingLabel(for phase: CapturePhase, elapsed: Int) -> String {
        HUDLabelPresenter.trailingLabel(phase: phase, recordingSeconds: elapsed)
    }

    /// Phases where the HUD takes clicks (stop button, KEEP).
    static func acceptsMouse(_ phase: CapturePhase) -> Bool {
        phase == .recording || phase == .canceled
    }

    /// YA-54: status line after the time limit stopped a dictation.
    static func autoStopStatus(limit: Int) -> String {
        let minutes = limit / 60
        let seconds = limit % 60
        let label = seconds == 0 ? L10n.tr("%@-minute", "\(minutes)") : String(format: "%d:%02d", minutes, seconds)
        return L10n.tr("Stopped at the %@ limit. Transcribing what you said.", label)
    }
}

/// YA-19: a canceled recording keeps its audio for a few seconds so KEEP can
/// still transcribe it. Pure state, with the clock passed in.
struct CancelUndoBuffer {
    static let window: TimeInterval = 5

    struct Pending {
        let audioURL: URL
        let session: Int
        let target: PasteTarget?
        let canceledAt: Date
    }

    private(set) var pending: Pending?

    mutating func hold(audioURL: URL, session: Int, target: PasteTarget?, at date: Date) -> URL? {
        let replaced = pending?.audioURL
        pending = Pending(audioURL: audioURL, session: session, target: target, canceledAt: date)
        return replaced
    }

    /// Takes the pending recording for UNDO if it is still inside the window.
    mutating func takeForUndo(now: Date) -> Pending? {
        guard let pending, now.timeIntervalSince(pending.canceledAt) <= Self.window else { return nil }
        self.pending = nil
        return pending
    }

    /// Drops the pending recording and returns its file for deletion. When
    /// `onlyIfExpired` is set, a recording still inside the window is kept.
    mutating func discard(now: Date, onlyIfExpired: Bool) -> URL? {
        guard let pending else { return nil }
        if onlyIfExpired, now.timeIntervalSince(pending.canceledAt) < Self.window {
            return nil
        }
        self.pending = nil
        return pending.audioURL
    }
}
