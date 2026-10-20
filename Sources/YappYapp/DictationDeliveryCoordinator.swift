import AppKit

/// What the delivery coordinator needs from the clipboard layer. ClipboardInjector
/// is the real one; the self-tests inject a fake so nothing touches the system
/// pasteboard or posts keystrokes.
protocol TranscriptDeliveryBackend: AnyObject {
    func insertOrCopy(_ text: String, config: AppConfig, target: PasteTarget?) -> PasteOutcome
    @discardableResult
    func copy(_ text: String, purpose: PasteboardWritePurpose) -> Int
    var lastPasteRestoresClipboard: Bool { get }
    /// DELIVERY-TRAIL: what the last insertOrCopy did, without the text.
    var lastDeliveryAttempt: DeliveryAttempt? { get }
}

extension TranscriptDeliveryBackend {
    var lastDeliveryAttempt: DeliveryAttempt? { nil }
}

/// Owns the end of the dictation pipeline: deciding where a finished
/// transcript goes, delivering it, and telling the user honestly what happened.
///
/// - YA-02: a finished transcript is never dropped. Mid-paste arrivals queue;
///   a superseded session is copied and announced instead of pasted.
/// - YA-03: confirmed, unconfirmed and not-delivered outcomes look different.
/// - YA-18: the text goes where the user is when it is ready: the app in
///   front at delivery, else the app in front when the recording stopped.
/// - Missing feature 3: a notification with COPY when it did not land and the
///   controls are closed.
@MainActor
final class DictationDeliveryCoordinator {
    private let state: YappYappState
    private let sessions: RecordingSessionCoordinator
    private let backend: TranscriptDeliveryBackend
    private let notifier: DeliveryNotifying

    /// True while the popover or control window is on screen.
    var controlsVisible: () -> Bool = { false }
    /// The app in front right now, nil when YappYapp itself is in front.
    var currentTarget: () -> PasteTarget? = { nil }
    /// Last external app, when neither the stop nor the current target exists.
    var fallbackTarget: () -> PasteTarget? = { nil }
    /// YA-61: the app holding secure input, when known.
    var secureInputHolder: () -> String? = { nil }
    /// YA-39: every paste outcome is also spoken once by VoiceOver.
    var onPresented: (PasteStatusSnapshot) -> Void = { _ in }
    /// LEARN-FROM-FIXES: every delivery's outcome and text, so the watcher
    /// can follow a paste. Called after the outcome is presented.
    var onDelivered: (PasteOutcome, String) -> Void = { _, _ in }

    /// In-memory only, never written to disk. Other features (paste-last)
    /// read this instead of keeping their own copy.
    private(set) var lastTranscript: String?

    init(
        state: YappYappState,
        sessions: RecordingSessionCoordinator,
        backend: TranscriptDeliveryBackend,
        notifier: DeliveryNotifying
    ) {
        self.state = state
        self.sessions = sessions
        self.backend = backend
        self.notifier = notifier
    }

    // MARK: - Reusable entry point

    /// Delivers `text` to `target` with the full honesty treatment: paste or
    /// copy, status, HUD phase, notification and return to idle. Reusable for
    /// paste-last. Callers must not invoke it while `sessions.isPasteInFlight`.
    @discardableResult
    func deliver(
        text: String,
        to target: PasteTarget?,
        elapsedLabel: String? = nil,
        hasPetNews: Bool = false,
        autoPasteOverride: Bool? = nil
    ) -> PasteOutcome {
        lastTranscript = text
        // PROFILES: a per-app paste choice applies to this delivery only.
        var config = state.config
        if let autoPasteOverride { config.autoPaste = autoPasteOverride }
        let outcome = backend.insertOrCopy(text, config: config, target: target)
        let holder = Self.isSecureInputOutcome(outcome) ? secureInputHolder() : nil
        recordTrail(outcome: outcome, target: target, attempt: backend.lastDeliveryAttempt, secureInputHolder: holder)
        present(outcome, transcript: text, elapsedLabel: elapsedLabel, hasPetNews: hasPetNews, secureInputHolder: holder)
        onDelivered(outcome, text)
        return outcome
    }

    // MARK: - Dictation pipeline

    /// Called when a session's transcript is ready.
    func completeDictation(
        transcript: String,
        session: Int,
        sessionTarget: PasteTarget?,
        elapsedLabel: String?,
        hasPetNews: Bool,
        autoPasteOverride: Bool? = nil
    ) {
        switch sessions.route(forFinished: session) {
        case .queueBehindPaste:
            sessions.enqueueAfterPaste { [weak self] in
                self?.completeDictation(
                    transcript: transcript,
                    session: session,
                    sessionTarget: sessionTarget,
                    elapsedLabel: elapsedLabel,
                    hasPetNews: hasPetNews,
                    autoPasteOverride: autoPasteOverride
                )
            }
        case .copySuperseded:
            copySuperseded(transcript)
        case .deliver:
            deliverCurrent(
                transcript: transcript,
                session: session,
                sessionTarget: sessionTarget,
                elapsedLabel: elapsedLabel,
                hasPetNews: hasPetNews,
                autoPasteOverride: autoPasteOverride
            )
        }
    }

    /// Called when a session's transcription failed.
    /// `holdSeconds` overrides how long the error stays, for example while
    /// the audio is kept for a retry (YA-05).
    func failDictation(session: Int, message: String, holdSeconds: TimeInterval? = nil, audioKept: Bool = false) {
        if !controlsVisible() {
            notifier.post(DeliveryNotificationPolicy.failureNotice(message: message, audioKept: audioKept))
        }
        guard sessions.isCurrent(session) else { return }
        state.phase = .error(message)
        state.statusText = message
        state.isProcessing = false
        sessions.scheduleReturnToIdle(after: holdSeconds ?? PasteOutcomePresenter.holdSeconds(for: .error(message)))
    }

    private func deliverCurrent(
        transcript: String,
        session: Int,
        sessionTarget: PasteTarget?,
        elapsedLabel: String?,
        hasPetNews: Bool,
        autoPasteOverride: Bool?
    ) {
        // `sessionTarget` is the app in front when the recording stopped. The
        // user may switch again while it transcribes; the text follows them.
        let current = currentTarget()
        let resolution = PasteTargetPolicy.resolve(currentPID: current?.application?.processIdentifier)

        // FIX(pasteReentry): insertOrCopy spins the run loop up to ~0.9s. Flag
        // the paste so a re-entrant hotkey toggle is dropped and any other
        // finished transcript queues behind this one.
        guard sessions.beginPaste(for: session) else {
            // Unreachable after route(forFinished:) said .deliver, but never drop.
            copySuperseded(transcript)
            return
        }

        switch resolution {
        case .current:
            deliver(
                text: transcript,
                to: current,
                elapsedLabel: elapsedLabel,
                hasPetNews: hasPetNews,
                autoPasteOverride: autoPasteOverride
            )
        case .stopTarget:
            deliver(
                text: transcript,
                to: sessionTarget ?? fallbackTarget(),
                elapsedLabel: elapsedLabel,
                hasPetNews: hasPetNews,
                autoPasteOverride: autoPasteOverride
            )
        }
        state.isProcessing = false
        sessions.endPaste()
    }

    /// YA-02: a newer dictation owns the HUD now, so this one goes to the
    /// clipboard and the user hears about it. The current phase is untouched.
    private func copySuperseded(_ transcript: String) {
        lastTranscript = transcript
        backend.copy(transcript, purpose: .copyOnlyDelivery)
        let outcome = PasteOutcome.copiedOnly(.newerDictation)
        recordTrail(
            outcome: outcome,
            target: nil,
            attempt: DeliveryAttempt(decision: "superseded", activation: .none, frontmostMatchedTarget: nil, restoresClipboard: false),
            secureInputHolder: nil
        )
        state.statusText = PasteOutcomePresenter.statusText(for: .newerDictation)
        notifyIfNeeded(outcome, transcript: transcript)
    }

    private static func isSecureInputOutcome(_ outcome: PasteOutcome) -> Bool {
        outcome == .withheld(.secureInputActive) || outcome == .copiedOnly(.secureInputActive)
    }

    /// DELIVERY-TRAIL: one line per delivery for the support report. Never
    /// the transcript.
    private func recordTrail(
        outcome: PasteOutcome,
        target: PasteTarget?,
        attempt: DeliveryAttempt?,
        secureInputHolder: String?
    ) {
        state.deliveryTrail.record(DeliveryTrailEntry(
            date: Date(),
            bundleIdentifier: target?.bundleIdentifier,
            targetKind: ClipboardInjector.targetKind(for: target?.bundleIdentifier),
            decision: attempt?.decision ?? "unknown",
            outcome: DeliveryTrail.outcomeLabel(outcome),
            activation: attempt?.activation ?? .none,
            frontmostMatchedTarget: attempt?.frontmostMatchedTarget,
            restoresClipboard: attempt?.restoresClipboard ?? false,
            secureInputHolder: secureInputHolder
        ))
    }

    private func present(
        _ outcome: PasteOutcome,
        transcript: String,
        elapsedLabel: String?,
        hasPetNews: Bool,
        secureInputHolder holder: String?
    ) {
        var snapshot = PasteOutcomePresenter.status(
            for: outcome,
            elapsedLabel: elapsedLabel,
            restoresClipboard: backend.lastPasteRestoresClipboard
        )
        if Self.isSecureInputOutcome(outcome) {
            snapshot = PasteStatusSnapshot(
                phase: snapshot.phase,
                statusText: snapshot.statusText + PasteOutcomePresenter.secureInputHolderSuffix(holder)
            )
        }
        // The indicator shows the speed of a confirmed paste (DONE IN 0.8S).
        state.pastedElapsedLabel = outcome == .pasted ? elapsedLabel : nil
        state.phase = snapshot.phase
        state.statusText = snapshot.statusText
        onPresented(snapshot)
        notifyIfNeeded(outcome, transcript: transcript)
        sessions.scheduleReturnToIdle(
            after: PasteOutcomePresenter.holdSeconds(for: snapshot.phase, hasPetNews: hasPetNews)
        )
    }

    private func notifyIfNeeded(_ outcome: PasteOutcome, transcript: String) {
        guard DeliveryNotificationPolicy.shouldNotify(for: outcome, controlsVisible: controlsVisible()) else { return }
        notifier.post(DeliveryNotificationPolicy.notice(
            for: outcome,
            transcript: transcript,
            showText: state.config.showTextInNotifications
        ))
    }
}
