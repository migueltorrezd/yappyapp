import AppKit

/// Owns live microphone/accessibility state and their repair polling loops.
/// Permission UI remains fully observable through `YappYappState`, while timer
/// lifetimes and stale-TCC bookkeeping no longer live in `AppDelegate`.
@MainActor
final class PermissionCoordinator {
    private let state: YappYappState
    private let recorder: RecordingController
    private let clipboard: ClipboardInjector
    private let persistConfig: (AppConfig) throws -> Void
    private let shouldPersistGuidedSetup: () -> Bool
    private let logNonFatal: (String) -> Void
    private let repairTimeout: TimeInterval

    private var accessibilityRepairTimer: Timer?
    private var accessibilityRepairStartedAt: Date?
    private var microphoneRepairTimer: Timer?
    private var microphoneRepairStartedAt: Date?
    private var accessibilityWasTrustedThisSession = false
    private var accessibilityGrantAttempts = 0

    init(
        state: YappYappState,
        recorder: RecordingController,
        clipboard: ClipboardInjector,
        repairTimeout: TimeInterval = 120,
        shouldPersistGuidedSetup: @escaping () -> Bool,
        persistConfig: @escaping (AppConfig) throws -> Void,
        logNonFatal: @escaping (String) -> Void
    ) {
        self.state = state
        self.recorder = recorder
        self.clipboard = clipboard
        self.repairTimeout = repairTimeout
        self.shouldPersistGuidedSetup = shouldPersistGuidedSetup
        self.persistConfig = persistConfig
        self.logNonFatal = logNonFatal
    }

    func stop() {
        stopAccessibilityRepairLoop()
        stopMicrophoneRepairLoop()
    }

    func requestAccessibilityAccess() {
        accessibilityGrantAttempts += 1
        let trusted = clipboard.accessibilityTrusted(promptIfNeeded: true)
        updateAccessibilityTrust(trusted)
        state.statusText = PasteOutcomePresenter.accessibilityRequestStatus(isTrusted: trusted)

        if trusted {
            stopAccessibilityRepairLoop()
        } else {
            startAccessibilityRepairLoop(openSettings: true)
        }
    }

    func updateAccessibilityTrust(_ trusted: Bool) {
        if trusted {
            accessibilityWasTrustedThisSession = true
        }
        state.isAccessibilityTrusted = trusted
        state.staleAccessibility = StaleAccessibilityDetector.verdict(
            for: StaleAccessibilitySignals(
                wantsAutoPaste: state.config.autoPaste,
                isTrusted: trusted,
                wasTrustedThisSession: accessibilityWasTrustedThisSession,
                grantAttempts: accessibilityGrantAttempts
            )
        )
        markGuidedSetupCompleteIfReady()
    }

    func resetAndRegrantAccessibility() {
        logNonFatal("accessibility: STALE-TCC-RESET invoked")
        let didReset = runTccResetAccessibility()
        state.statusText = PasteOutcomePresenter.staleResetStatus(didReset: didReset)
        requestAccessibilityAccess()
    }

    func requestMicrophoneAccess() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await recorder.requestMicrophoneAccess()
            refreshMicrophoneState()
            if granted {
                stopMicrophoneRepairLoop()
            } else {
                startMicrophoneRepairLoop(openSettings: false)
            }
        }
    }

    func refreshMicrophoneState() {
        let status = recorder.microphoneAuthorizationStatus()
        state.isMicrophoneAuthorized = PermissionDiagnostics.isMicrophoneAuthorized(status)
        state.isMicrophoneDenied = PermissionDiagnostics.isMicrophoneDenied(status)
        markGuidedSetupCompleteIfReady()
    }

    func openMicrophonePrivacySettings() {
        openPrivacyPane("Privacy_Microphone")
        startMicrophoneRepairLoop(openSettings: false)
    }

    func refreshAccessibilityTrust() -> Bool {
        let trusted = clipboard.accessibilityTrusted(promptIfNeeded: false)
        updateAccessibilityTrust(trusted)
        return trusted
    }

    func markGuidedSetupCompleteIfReady() {
        guard shouldPersistGuidedSetup() else { return }
        guard !state.config.hasCompletedGuidedSetup else { return }

        let accessibilityReady = !state.config.autoPaste || state.isAccessibilityTrusted
        guard state.isModelReady, state.isMicrophoneAuthorized, accessibilityReady else { return }

        var config = state.config
        config.hasCompletedGuidedSetup = true
        do {
            try persistConfig(config)
            state.config = config
        } catch {
            logNonFatal("Could not persist guided setup completion: \(error.localizedDescription)")
        }
    }

    private func runTccResetAccessibility() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "app.yappyapp.YappYapp"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            logNonFatal("accessibility: tccutil reset failed: \(error.localizedDescription)")
            return false
        }
    }

    private func startMicrophoneRepairLoop(openSettings: Bool) {
        stopMicrophoneRepairLoop()
        microphoneRepairStartedAt = Date()
        if openSettings {
            openPrivacyPane("Privacy_Microphone")
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMicrophoneRepairLoop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        microphoneRepairTimer = timer
        pollMicrophoneRepairLoop()
    }

    private func pollMicrophoneRepairLoop() {
        refreshMicrophoneState()
        if state.isMicrophoneAuthorized {
            stopMicrophoneRepairLoop()
            return
        }

        let elapsed = microphoneRepairStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if elapsed >= repairTimeout {
            stopMicrophoneRepairLoop()
        }
    }

    private func stopMicrophoneRepairLoop() {
        microphoneRepairTimer?.invalidate()
        microphoneRepairTimer = nil
        microphoneRepairStartedAt = nil
    }

    private func startAccessibilityRepairLoop(openSettings: Bool) {
        stopAccessibilityRepairLoop()
        accessibilityRepairStartedAt = Date()
        if openSettings {
            openPrivacyPane("Privacy_Accessibility")
        }

        state.statusText = PasteOutcomePresenter.accessibilityRepairWaitingStatus()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollAccessibilityRepairLoop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityRepairTimer = timer
        pollAccessibilityRepairLoop()
    }

    private func pollAccessibilityRepairLoop() {
        let trusted = refreshAccessibilityTrust()
        if trusted {
            stopAccessibilityRepairLoop()
            state.statusText = PasteOutcomePresenter.accessibilityRequestStatus(isTrusted: true)
            return
        }

        let elapsed = accessibilityRepairStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if elapsed >= repairTimeout {
            stopAccessibilityRepairLoop()
            state.statusText = PasteOutcomePresenter.accessibilityRepairTimedOutStatus()
        } else {
            state.statusText = PasteOutcomePresenter.accessibilityRepairWaitingStatus()
        }
    }

    private func stopAccessibilityRepairLoop() {
        accessibilityRepairTimer?.invalidate()
        accessibilityRepairTimer = nil
        accessibilityRepairStartedAt = nil
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
