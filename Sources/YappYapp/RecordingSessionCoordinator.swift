import Foundation

/// Owns capture-generation state and every session-scoped timer/task.
///
/// A new recording may begin while an older transcription finishes. The
/// generation token makes that overlap explicit and prevents stale timeouts,
/// paste results, or callbacks from mutating the current recording.
@MainActor
final class RecordingSessionCoordinator {
    private let state: YappYappState
    private let recorder: RecordingController

    private(set) var currentSession = 0
    private(set) var isPasteInFlight = false
    private var pendingPasteTarget: PasteTarget?
    private var autoStopTask: Task<Void, Never>?
    private var returnToIdleTask: Task<Void, Never>?
    private var levelTimer: Timer?
    // YA-02: deliveries that arrived while another paste was in flight.
    private var queuedDeliveries: [@MainActor () -> Void] = []

    init(state: YappYappState, recorder: RecordingController) {
        self.state = state
        self.recorder = recorder
    }

    @discardableResult
    func begin(target: PasteTarget?) -> Int {
        currentSession += 1
        pendingPasteTarget = target
        returnToIdleTask?.cancel()
        return currentSession
    }

    func isCurrent(_ session: Int) -> Bool {
        currentSession == session
    }

    func takePendingPasteTarget() -> PasteTarget? {
        defer { pendingPasteTarget = nil }
        return pendingPasteTarget
    }

    func clearPendingPasteTarget() {
        pendingPasteTarget = nil
    }

    @discardableResult
    func beginPaste(for session: Int) -> Bool {
        guard isCurrent(session), !isPasteInFlight else { return false }
        isPasteInFlight = true
        return true
    }

    func endPaste() {
        isPasteInFlight = false
        drainQueuedDeliveries()
    }

    var queuedDeliveryCount: Int {
        queuedDeliveries.count
    }

    /// YA-02: a finished transcript is never dropped. Anything that arrives
    /// mid-paste waits its turn; a superseded session is copied, not pasted.
    func route(forFinished session: Int) -> DeliveryRoute {
        if isPasteInFlight { return .queueBehindPaste }
        return isCurrent(session) ? .deliver : .copySuperseded
    }

    func enqueueAfterPaste(_ delivery: @escaping @MainActor () -> Void) {
        queuedDeliveries.append(delivery)
    }

    private func drainQueuedDeliveries() {
        // One at a time: a drained delivery may start its own paste, which
        // drains the rest when it ends.
        while !isPasteInFlight, !queuedDeliveries.isEmpty {
            let next = queuedDeliveries.removeFirst()
            next()
        }
    }

    func startLevelMonitoring() {
        levelTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.pushLevel(Double(self.recorder.meterLevel))

                let seconds = Int(self.recorder.duration)
                if seconds != self.state.recordingSeconds {
                    self.state.recordingSeconds = seconds
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        state.resetLevels()
    }

    func scheduleAutoStop(
        after seconds: Int,
        for session: Int,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            guard self.isCurrent(session), self.state.phase == .recording else { return }
            onTimeout()
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    func scheduleReturnToIdle(after delay: TimeInterval) {
        returnToIdleTask?.cancel()
        returnToIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            switch self.state.phase {
            case .recording, .transcribing, .canceled:
                // .canceled: the UNDO window owns its own return to idle.
                break
            default:
                self.state.phase = .idle
            }
        }
    }

    /// HUD-RETURNS-TO-IDLE: an outcome that did not come from a dictation
    /// (COPY in HISTORY or FILES, the support report, a save that failed).
    /// It never takes the indicator from a dictation in progress, and like a
    /// delivery outcome it always goes back to idle after its hold time.
    func presentTransient(_ phase: CapturePhase, statusText: String, hold: TimeInterval? = nil) {
        state.statusText = statusText
        guard let shown = HUDTransientPolicy.phaseToShow(phase, over: state.phase) else { return }
        state.phase = shown
        scheduleReturnToIdle(after: hold ?? HUDTransientPolicy.holdSeconds(for: shown))
    }

    func shutdown() {
        cancelAutoStop()
        returnToIdleTask?.cancel()
        returnToIdleTask = nil
        stopLevelMonitoring()
        clearPendingPasteTarget()
        isPasteInFlight = false
        queuedDeliveries.removeAll()
    }
}

/// HUD-RETURNS-TO-IDLE: pure rules for outcomes set outside a dictation.
enum HUDTransientPolicy {
    /// The phase to show, or nil when a dictation owns the indicator
    /// (listening, transcribing, or the KEEP window after a cancel). Only
    /// the status line changes then.
    static func phaseToShow(_ requested: CapturePhase, over current: CapturePhase) -> CapturePhase? {
        switch current {
        case .recording, .transcribing, .canceled:
            return nil
        default:
            return requested
        }
    }

    /// Same hold as a delivery outcome with the same look.
    static func holdSeconds(for phase: CapturePhase) -> TimeInterval {
        PasteOutcomePresenter.holdSeconds(for: phase)
    }
}
