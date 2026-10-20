#if DEBUG
import AppKit
import Foundation

// Self-tests owned by the "pipeline" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func pipelineTrackTests() {
        pipelineOverlapTests()
        pipelinePresenterTests()
        pipelineHUDTests()
        pipelineNotificationTests()
        pipelinePasteboardTests()
        pipelineSystemLookupTests()
        pipelineTempFileTests()
        pipelineConfigTests()
    }

    // MARK: - Fakes

    /// Records every delivery instead of touching the system pasteboard or
    /// posting keystrokes.
    final class FakeDeliveryBackend: TranscriptDeliveryBackend {
        var outcome: PasteOutcome = .pasted
        var restores = false
        var inserted: [(text: String, targetPID: pid_t?)] = []
        var copied: [(text: String, purpose: PasteboardWritePurpose)] = []
        var onInsert: (() -> Void)?

        var lastPasteRestoresClipboard: Bool { restores }

        func insertOrCopy(_ text: String, config: AppConfig, target: PasteTarget?) -> PasteOutcome {
            inserted.append((text, target?.application?.processIdentifier))
            onInsert?()
            return outcome
        }

        @discardableResult
        func copy(_ text: String, purpose: PasteboardWritePurpose) -> Int {
            copied.append((text, purpose))
            return copied.count
        }
    }

    @MainActor
    final class FakeDeliveryNotifier: DeliveryNotifying {
        var notices: [DeliveryNotice] = []
        func post(_ notice: DeliveryNotice) {
            notices.append(notice)
        }
    }

    private static func makePipeline() -> (
        state: YappYappState,
        sessions: RecordingSessionCoordinator,
        backend: FakeDeliveryBackend,
        notifier: FakeDeliveryNotifier,
        delivery: DictationDeliveryCoordinator
    ) {
        let state = YappYappState()
        let sessions = RecordingSessionCoordinator(state: state, recorder: RecordingController())
        let backend = FakeDeliveryBackend()
        let notifier = FakeDeliveryNotifier()
        let delivery = DictationDeliveryCoordinator(
            state: state,
            sessions: sessions,
            backend: backend,
            notifier: notifier
        )
        return (state, sessions, backend, notifier, delivery)
    }

    /// Our own process stands in for one app; any other running app for a
    /// second one. Reading the running-app list is passive.
    private static func twoApplications() -> (NSRunningApplication, NSRunningApplication)? {
        let current = NSRunningApplication.current
        guard let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != current.processIdentifier
        }) else { return nil }
        return (current, other)
    }

    private static func pipelineScratchDirectory(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment[AppPaths.applicationSupportBaseEnvironmentKey]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? temporaryURL("-pipeline")
        let directory = base.appendingPathComponent("pipeline-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - YA-02 overlap

    private static func pipelineOverlapTests() {
        test("pipeline.overlapCopiesSupersededTranscriptAndNotifies") {
            let pipeline = makePipeline()
            let first = pipeline.sessions.begin(target: nil)
            let second = pipeline.sessions.begin(target: nil)
            pipeline.state.phase = .recording

            expectEqual(pipeline.sessions.route(forFinished: first), .copySuperseded)
            expectEqual(pipeline.sessions.route(forFinished: second), .deliver)

            // A finishes while B records: copied, announced, never dropped.
            pipeline.delivery.completeDictation(
                transcript: "first words",
                session: first,
                sessionTarget: nil,
                elapsedLabel: "1.0s",
                hasPetNews: false
            )
            expectEqual(pipeline.backend.copied.map(\.text), ["first words"])
            expectEqual(pipeline.backend.copied.first?.purpose, .copyOnlyDelivery)
            expect(pipeline.backend.inserted.isEmpty, "a superseded transcript must not be pasted")
            expectEqual(pipeline.state.phase, .recording, "the newer session keeps the HUD")
            expectEqual(pipeline.state.statusText, PasteOutcomePresenter.statusText(for: .newerDictation))
            expectEqual(pipeline.delivery.lastTranscript, "first words")
            expectEqual(pipeline.notifier.notices.count, 1)
            expectEqual(pipeline.notifier.notices.first?.title, "Copied, not pasted")
            expectEqual(pipeline.notifier.notices.first?.copyText, "first words")
            expect(pipeline.notifier.notices.first?.body.contains("first words") == false,
                   "no transcript text in the notification by default")

            // B finishes: pasted normally, no extra notice.
            pipeline.delivery.completeDictation(
                transcript: "second words",
                session: second,
                sessionTarget: nil,
                elapsedLabel: "1.0s",
                hasPetNews: false
            )
            expectEqual(pipeline.backend.inserted.map(\.text), ["second words"])
            expectEqual(pipeline.state.phase, .pasted)
            expectEqual(pipeline.notifier.notices.count, 1)
            expect(!pipeline.sessions.isPasteInFlight, "paste flag cleared after delivery")
            expectEqual(pipeline.delivery.lastTranscript, "second words")
        }

        test("pipeline.overlapQueuesBehindInFlightPasteInOrder") {
            let pipeline = makePipeline()
            let session = pipeline.sessions.begin(target: nil)
            expect(pipeline.sessions.beginPaste(for: session), "paste flag set")

            expectEqual(pipeline.sessions.route(forFinished: session), .queueBehindPaste)
            pipeline.delivery.completeDictation(
                transcript: "queued one",
                session: session,
                sessionTarget: nil,
                elapsedLabel: nil,
                hasPetNews: false
            )
            pipeline.delivery.completeDictation(
                transcript: "queued two",
                session: session,
                sessionTarget: nil,
                elapsedLabel: nil,
                hasPetNews: false
            )
            expectEqual(pipeline.sessions.queuedDeliveryCount, 2)
            expect(pipeline.backend.inserted.isEmpty, "nothing pastes while another paste is in flight")

            pipeline.sessions.endPaste()
            expectEqual(pipeline.sessions.queuedDeliveryCount, 0)
            expectEqual(pipeline.backend.inserted.map(\.text), ["queued one", "queued two"],
                        "queued transcripts land in order")
        }

        test("pipeline.queuedDeliveryDuringPasteSpinIsNotLost") {
            // Re-entrancy: while one paste spins the run loop, an older session
            // finishes. It must wait, then be copied rather than dropped.
            let pipeline = makePipeline()
            let older = pipeline.sessions.begin(target: nil)
            let newer = pipeline.sessions.begin(target: nil)
            pipeline.backend.onInsert = { [weak delivery = pipeline.delivery] in
                delivery?.completeDictation(
                    transcript: "older words",
                    session: older,
                    sessionTarget: nil,
                    elapsedLabel: nil,
                    hasPetNews: false
                )
            }
            pipeline.delivery.completeDictation(
                transcript: "newer words",
                session: newer,
                sessionTarget: nil,
                elapsedLabel: nil,
                hasPetNews: false
            )
            pipeline.backend.onInsert = nil
            expectEqual(pipeline.backend.inserted.map(\.text), ["newer words"])
            expectEqual(pipeline.backend.copied.map(\.text), ["older words"])
            expectEqual(pipeline.sessions.queuedDeliveryCount, 0)
        }

        test("pipeline.shutdownClearsQueuedDeliveries") {
            let pipeline = makePipeline()
            let session = pipeline.sessions.begin(target: nil)
            _ = pipeline.sessions.beginPaste(for: session)
            pipeline.sessions.enqueueAfterPaste {}
            pipeline.sessions.shutdown()
            expectEqual(pipeline.sessions.queuedDeliveryCount, 0)
            expect(!pipeline.sessions.isPasteInFlight, "shutdown clears the paste flag")
        }

        test("pipeline.appSwitchPastesWhereTheUserIs") {
            guard let (stopApp, otherApp) = twoApplications() else { return }
            let pipeline = makePipeline()
            let session = pipeline.sessions.begin(target: nil)
            let stopTarget = PasteTarget(application: stopApp, focusedElement: nil, bundleIdentifier: nil)
            let otherTarget = PasteTarget(application: otherApp, focusedElement: nil, bundleIdentifier: nil)

            // The user switched again while it transcribed: paste where they are now.
            pipeline.delivery.currentTarget = { otherTarget }
            pipeline.delivery.completeDictation(
                transcript: "follow me",
                session: session,
                sessionTarget: stopTarget,
                elapsedLabel: nil,
                hasPetNews: false
            )
            expectEqual(pipeline.backend.inserted.map(\.text), ["follow me"], "an app switch still pastes")
            expectEqual(pipeline.backend.inserted.last?.targetPID, otherApp.processIdentifier, "into the app in front now")
            expect(pipeline.backend.copied.isEmpty, "no copy-only because the app changed")
            expectEqual(pipeline.state.phase, .pasted)

            // Same app at stop and delivery: paste into it.
            let sameSession = pipeline.sessions.begin(target: nil)
            pipeline.delivery.currentTarget = { stopTarget }
            pipeline.delivery.completeDictation(
                transcript: "same app",
                session: sameSession,
                sessionTarget: stopTarget,
                elapsedLabel: nil,
                hasPetNews: false
            )
            expectEqual(pipeline.backend.inserted.last?.text, "same app")
            expectEqual(pipeline.backend.inserted.last?.targetPID, stopApp.processIdentifier)

            // YappYapp in front at delivery: use the stop target.
            let ownSession = pipeline.sessions.begin(target: nil)
            pipeline.delivery.currentTarget = { nil }
            pipeline.delivery.completeDictation(
                transcript: "from the popover",
                session: ownSession,
                sessionTarget: otherTarget,
                elapsedLabel: nil,
                hasPetNews: false
            )
            expectEqual(pipeline.backend.inserted.last?.targetPID, otherApp.processIdentifier)
        }

        test("pipeline.policyResolvesPasteTarget") {
            expectEqual(PasteTargetPolicy.resolve(currentPID: 11), .current)
            expectEqual(PasteTargetPolicy.resolve(currentPID: nil), .stopTarget)
        }

        test("pipeline.transientOutcomesReturnToIdle") {
            // HUD-RETURNS-TO-IDLE: COPY in HISTORY used to leave the bar
            // expanded forever. Every outcome set outside a dictation goes
            // back to idle after its hold.
            let pipeline = makePipeline()
            for phase: CapturePhase in [.copied, .error("Setup wasn't saved.")] {
                pipeline.sessions.presentTransient(phase, statusText: "x", hold: 0.05)
                expectEqual(pipeline.state.phase, phase, "shown first")
                let deadline = Date().addingTimeInterval(2)
                while pipeline.state.phase != .idle, Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                expectEqual(pipeline.state.phase, .idle, "\(phase.label) returns to idle")
            }
            // A dictation in progress keeps the indicator; only the status line changes.
            pipeline.state.phase = .recording
            pipeline.sessions.presentTransient(.copied, statusText: "Copied to the clipboard.", hold: 0.05)
            expectEqual(pipeline.state.phase, .recording, "COPY never interrupts a dictation")
            expectEqual(pipeline.state.statusText, "Copied to the clipboard.")
            pipeline.sessions.shutdown()
        }

        test("pipeline.focusAtDeliveryRules") {
            let own = ProcessInfo.processInfo.processIdentifier
            let ghostty: pid_t = 501
            let other: pid_t = 777
            func facts(front: pid_t?, focused: pid_t?, active: Bool = false, key: Bool = false) -> DeliveryFocusPolicy.Facts {
                DeliveryFocusPolicy.Facts(targetPID: ghostty, frontmostPID: front, focusedAppPID: focused, yappyappActive: active, yappyappHasKeyWindow: key)
            }
            expect(!DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty)), "really in front: left alone")
            expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: own)), "keyboard elsewhere: activate")
            expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty, active: true)), "YappYapp active: activate")
            expect(DeliveryFocusPolicy.needsActivation(facts(front: ghostty, focused: ghostty, key: true)), "YappYapp key window: activate")
            expect(DeliveryFocusPolicy.needsActivation(facts(front: other, focused: other)), "another app in front: activate")
            expect(!DeliveryFocusPolicy.admits(.captured, elementPID: ghostty, targetPID: ghostty, ownPID: own), "never a stale element")
            expect(!DeliveryFocusPolicy.admits(.systemFocused, elementPID: own, targetPID: nil, ownPID: own), "never YappYapp's own field")
            expect(!DeliveryFocusPolicy.admits(.systemFocused, elementPID: other, targetPID: ghostty, ownPID: own), "not another app's field")
            expect(!PasteTargetMemory.deactivationRefreshes(deactivatedPID: other, rememberedPID: ghostty), "late deactivation keeps the new app")
        }

        test("pipeline.sessionTargetIsTheStopApp") {
            guard let (startApp, stopApp) = twoApplications() else { return }
            let start = PasteTarget(application: startApp, focusedElement: nil, bundleIdentifier: "com.example.start")
            let stop = PasteTarget(application: stopApp, focusedElement: nil, bundleIdentifier: "com.example.stop")
            expectEqual(
                DictationTargetPolicy.sessionTarget(stopTarget: stop, startTarget: start)?.bundleIdentifier,
                "com.example.stop", "the app where the dictation ends wins"
            )
            expectEqual(
                DictationTargetPolicy.sessionTarget(stopTarget: nil, startTarget: start)?.bundleIdentifier,
                "com.example.start", "the start app is only the fallback"
            )
            expect(DictationTargetPolicy.sessionTarget(stopTarget: nil, startTarget: nil) == nil, "no app, no target")
        }

        test("pipeline.outcomesDriveDistinctPhases") {
            let pipeline = makePipeline()
            var session = pipeline.sessions.begin(target: nil)

            pipeline.backend.outcome = .pastedBestEffort
            pipeline.delivery.completeDictation(transcript: "a", session: session, sessionTarget: nil, elapsedLabel: nil, hasPetNews: false)
            expectEqual(pipeline.state.phase, .sentUnconfirmed)
            expect(pipeline.notifier.notices.isEmpty, "best-effort does not notify")

            session = pipeline.sessions.begin(target: nil)
            pipeline.backend.outcome = .pastedBestEffort
            pipeline.backend.restores = true
            pipeline.delivery.completeDictation(transcript: "b", session: session, sessionTarget: nil, elapsedLabel: nil, hasPetNews: false)
            expect(pipeline.state.statusText.contains("COPY"), "restore on: point to COPY")
            expect(!pipeline.state.statusText.contains("Cmd+V"), "restore on: never say Cmd+V")
            pipeline.backend.restores = false

            session = pipeline.sessions.begin(target: nil)
            pipeline.backend.outcome = .withheld(.secureInputActive)
            pipeline.delivery.secureInputHolder = { "Vault" }
            pipeline.delivery.completeDictation(transcript: "secret", session: session, sessionTarget: nil, elapsedLabel: nil, hasPetNews: false)
            expectEqual(pipeline.state.phase, .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT · TEXT KEPT"))
            expect(pipeline.state.statusText.hasSuffix("Vault turned it on."), "names the holder")
            // P0: the withheld text is still in HISTORY (recorded before the paste), so the line points there.
            expect(pipeline.state.statusText.contains("HISTORY"), "points to HISTORY")
            expectEqual(pipeline.notifier.notices.last?.copyIsSensitive, true)
            expectEqual(pipeline.notifier.notices.last?.title, "Dictation not pasted")

            session = pipeline.sessions.begin(target: nil)
            pipeline.backend.outcome = .copiedOnly(.autoPasteOff)
            let before = pipeline.notifier.notices.count
            pipeline.delivery.completeDictation(transcript: "c", session: session, sessionTarget: nil, elapsedLabel: nil, hasPetNews: false)
            expectEqual(pipeline.state.phase, .notDelivered(headline: "COPIED ONLY", reason: "AUTO-PASTE OFF · ⌘V TO PASTE"))
            expectEqual(pipeline.notifier.notices.count, before, "copy-only by choice does not notify")

            session = pipeline.sessions.begin(target: nil)
            pipeline.backend.outcome = .copiedOnly(.focusUnclear)
            pipeline.delivery.controlsVisible = { true }
            pipeline.delivery.completeDictation(transcript: "d", session: session, sessionTarget: nil, elapsedLabel: nil, hasPetNews: false)
            expectEqual(pipeline.notifier.notices.count, before, "open controls show it instead of a banner")
            pipeline.delivery.controlsVisible = { false }
        }

        test("pipeline.failureNotifiesAndKeepsNewerPhase") {
            let pipeline = makePipeline()
            let older = pipeline.sessions.begin(target: nil)
            _ = pipeline.sessions.begin(target: nil)
            pipeline.state.phase = .recording
            pipeline.delivery.failDictation(session: older, message: "Transcription timed out.")
            expectEqual(pipeline.state.phase, .recording)
            expectEqual(pipeline.notifier.notices.last?.title, "Dictation didn't work")
            expectEqual(pipeline.notifier.notices.last?.copyText, nil)

            let current = pipeline.sessions.currentSession
            pipeline.delivery.failDictation(session: current, message: "Transcription timed out.")
            expectEqual(pipeline.state.phase, .error("Transcription timed out."))
        }

        test("pipeline.deliverEntryPointIsReusable") {
            let pipeline = makePipeline()
            let outcome = pipeline.delivery.deliver(text: "paste last", to: nil)
            expectEqual(outcome, .pasted)
            expectEqual(pipeline.backend.inserted.map(\.text), ["paste last"])
            expectEqual(pipeline.delivery.lastTranscript, "paste last")
            expectEqual(pipeline.state.phase, .pasted)
        }
    }

    // MARK: - YA-03 presenter

    private static func pipelinePresenterTests() {
        test("pipeline.presenterBestEffortPointsToCopyWhenRestoring") {
            let restoring = PasteOutcomePresenter.status(for: .pastedBestEffort, elapsedLabel: "2.0s", restoresClipboard: true)
            expectEqual(restoring.phase, .sentUnconfirmed)
            expectEqual(restoring.statusText, "Done in 2.0s. Pasted, but the app didn't confirm. Nothing there? Press COPY in HISTORY.")
            let keeping = PasteOutcomePresenter.status(for: .pastedBestEffort, restoresClipboard: false)
            expectEqual(keeping.statusText, "Pasted, but the app didn't confirm. Nothing there? Press ⌘V.")
        }

        test("pipeline.presenterNewReasons") {
            expectEqual(
                PasteOutcomePresenter.status(for: .copiedOnly(.autoPasteOff)).phase,
                .notDelivered(headline: "COPIED ONLY", reason: "AUTO-PASTE OFF · ⌘V TO PASTE")
            )
            for reason: ClipboardPasteBlockReason in [.autoPasteOff, .focusUnclear, .newerDictation] {
                let withheld = PasteOutcomePresenter.status(for: .withheld(reason)).statusText
                expect(!withheld.contains("⌘V"), "withheld(\(reason)) never promises ⌘V")
                expect(!PasteOutcomePresenter.hudCause(for: reason).isEmpty, "every reason has a HUD line")
            }
        }

        test("pipeline.presenterHoldTimesAndErrorLabels") {
            expectEqual(PasteOutcomePresenter.holdSeconds(for: .pasted), 1.4)
            expectEqual(PasteOutcomePresenter.holdSeconds(for: .pasted, hasPetNews: true), 3.0)
            expect(PasteOutcomePresenter.holdSeconds(for: .error("x")) >= 5, "errors stay long enough to read")
            expect(PasteOutcomePresenter.holdSeconds(for: .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT")) >= 5,
                   "not-delivered stays long enough to read")
            expectEqual(PasteOutcomePresenter.errorShortLabel("Transcription timed out."), "TIMED OUT")
            expectEqual(PasteOutcomePresenter.errorShortLabel("Heard nothing."), "HEARD NOTHING")
            expectEqual(PasteOutcomePresenter.errorShortLabel("The audio device changed"), "MIC TROUBLE")
            expectEqual(PasteOutcomePresenter.errorShortLabel("Download Parakeet TDT v3 from Models"), "DOWNLOAD NEEDED")
            expectEqual(PasteOutcomePresenter.errorShortLabel("something odd"), "DIDN'T WORK")
            expectEqual(PasteOutcomePresenter.errorShortLabel("Transcribing took too long."), "TIMED OUT")
            expectEqual(PasteOutcomePresenter.errorShortLabel("The mic didn't start. Pick another mic in Setup."), "MIC TROUBLE")
            expectEqual(PasteOutcomePresenter.errorShortLabel("Whisper heard no words. Try again a little louder."), "HEARD NOTHING")
            expectEqual(PasteOutcomePresenter.secureInputHolderSuffix(nil), "")
            expectEqual(PasteOutcomePresenter.secureInputHolderSuffix("Terminal"), " Terminal turned it on.")
        }

        test("pipeline.petCelebratesConfirmedPasteOnly") {
            expect(PetCelebrationPolicy.celebrates(.pasted), "confirmed paste celebrates")
            for phase: CapturePhase in [
                .copied, .sentUnconfirmed, .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT"),
                .canceled, .error("x"), .idle, .recording, .transcribing
            ] {
                expect(!PetCelebrationPolicy.celebrates(phase), "\(phase) must not celebrate")
            }
        }

        test("pipeline.newPhaseLabels") {
            expectEqual(CapturePhase.sentUnconfirmed.label, "Pasted?")
            expectEqual(CapturePhase.notDelivered(headline: "NOT PASTED", reason: "X").label, "Not Pasted")
            expectEqual(CapturePhase.notDelivered(headline: "COPIED ONLY", reason: "X").label, "Copied Only")
            expectEqual(CapturePhase.canceled.label, "Canceled")
            expectEqual(CapturePhase.canceled.symbolName, "xmark")
        }
    }

    // MARK: - HUD (YA-03, YA-19, YA-54)

    private static func pipelineHUDTests() {
        test("pipeline.hudCountdownInLastTenSeconds") {
            expectEqual(HUDPresenter.countdown(elapsed: 289, limit: 300), nil)
            expectEqual(HUDPresenter.countdown(elapsed: 290, limit: 300), 10)
            expectEqual(HUDPresenter.countdown(elapsed: 299, limit: 300), 1)
            expectEqual(HUDPresenter.countdown(elapsed: 300, limit: 300), nil)
            var config = AppConfig.defaultConfig
            config.maxRecordingSeconds = 3
            expectEqual(HUDPresenter.limitSeconds(for: config), 10, "matches the auto-stop floor")
            expectEqual(HUDPresenter.autoStopStatus(limit: 300), "Stopped at the 5-minute limit. Transcribing what you said.")
            expectEqual(HUDPresenter.autoStopStatus(limit: 90), "Stopped at the 1:30 limit. Transcribing what you said.")
        }

        test("pipeline.hudCaptionsAndLabels") {
            expectEqual(HUDPresenter.caption(for: .recording, escCancels: true, countdown: nil, note: nil), "ESC TO CANCEL")
            expectEqual(HUDPresenter.caption(for: .recording, escCancels: false, countdown: nil, note: nil), nil)
            expectEqual(HUDPresenter.caption(for: .recording, escCancels: true, countdown: 7, note: nil), "AUTO-STOP IN 7S")
            expectEqual(HUDPresenter.caption(for: .transcribing, escCancels: true, countdown: nil, note: "TIME LIMIT"), "TIME LIMIT")
            expectEqual(
                HUDPresenter.caption(for: .notDelivered(headline: "COPIED ONLY", reason: "NO TEXT FIELD"), escCancels: true, countdown: nil, note: nil),
                "NO TEXT FIELD"
            )
            // The generic error word sits in the trailing box; the caption only
            // repeats it when RETRY takes that box.
            expectEqual(HUDPresenter.caption(for: .error("something odd"), escCancels: true, countdown: nil, note: nil), nil)
            expectEqual(
                HUDPresenter.caption(for: .error("something odd"), escCancels: true, countdown: nil, note: nil, retryShown: true),
                "DIDN'T WORK"
            )
            expectEqual(HUDPresenter.caption(for: .canceled, escCancels: true, countdown: nil, note: nil), "CANCELED · KEEP IT? 5S")
            expectEqual(HUDPresenter.caption(for: .sentUnconfirmed, escCancels: true, countdown: nil, note: nil), "CHECK THE APP")
            expectEqual(HUDPresenter.caption(for: .error("Transcription timed out."), escCancels: true, countdown: nil, note: nil), "TIMED OUT")
            expectEqual(HUDPresenter.trailingLabel(for: .pasted, elapsed: 0), "PASTED")
            expectEqual(HUDPresenter.trailingLabel(for: .transcribing, elapsed: 0), "TRANSCRIBING")
            expectEqual(HUDPresenter.trailingLabel(for: .sentUnconfirmed, elapsed: 0), "PASTED?")
            expectEqual(HUDPresenter.trailingLabel(for: .notDelivered(headline: "NOT PASTED", reason: "x"), elapsed: 0), "NOT PASTED")
            expectEqual(HUDPresenter.trailingLabel(for: .error("x"), elapsed: 0), "DIDN'T WORK")
            expectEqual(HUDPresenter.trailingLabel(for: .canceled, elapsed: 0), "KEEP")
            expectEqual(HUDPresenter.trailingLabel(for: .recording, elapsed: 75), "1:15")
            expect(HUDPresenter.acceptsMouse(.recording), "stop button")
            expect(HUDPresenter.acceptsMouse(.canceled), "KEEP button")
            expect(!HUDPresenter.acceptsMouse(.pasted), "outcomes stay click-through")
        }

        test("pipeline.hudRendersEveryOutcomePhase") {
            let state = YappYappState()
            for phase: CapturePhase in [
                .pasted, .sentUnconfirmed, .notDelivered(headline: "COPIED ONLY", reason: "NO TEXT FIELD"),
                .canceled, .error("Transcription timed out.")
            ] {
                state.phase = phase
                for vertical in [false, true] {
                    let size = BrutalistHUDView.size(vertical: vertical)
                    let image = renderImage(BrutalistHUDView(state: state, vertical: vertical), width: size.width, height: size.height)
                    expect(image != nil, "HUD renders \(phase) vertical=\(vertical)")
                }
            }
            state.phase = .recording
            state.recordingSeconds = 295
            let size = BrutalistHUDView.size(vertical: false)
            expect(renderImage(BrutalistHUDView(state: state), width: size.width, height: size.height) != nil,
                   "HUD renders the countdown")
        }

        test("pipeline.indicatorIsCompactAndWordless") {
            let horizontal = BrutalistHUDView.size(vertical: false)
            let vertical = BrutalistHUDView.size(vertical: true)
            expect(horizontal.width <= 180 && horizontal.height <= 28, "compact bar: \(horizontal)")
            expectEqual(vertical.width, horizontal.height, "vertical bar is the same bar turned")
            expectEqual(vertical.height, horizontal.width)
            expect(IndicatorMetrics.idleLength * IndicatorMetrics.idleThickness <= 56 * 10 / 2, "idle pill at most half the old one")

            let phases: [CapturePhase] = [
                .idle, .recording, .transcribing, .copied, .pasted, .sentUnconfirmed,
                .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT"), .canceled, .error("x")
            ]
            var fills: [String: IndicatorState.Fill] = [:]
            for phase in phases {
                for retry in [false, true] {
                    let model = IndicatorState.make(phase: phase, isCleaning: false, retryAvailable: retry)
                    expect(model.visibleText.isEmpty, "no words on the bar for \(phase.label)")
                    if let symbol = model.symbol {
                        expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is a real symbol")
                    }
                    if let action = model.action {
                        expect(NSImage(systemSymbolName: IndicatorState.symbol(for: action), accessibilityDescription: nil) != nil,
                               "action glyph exists")
                    }
                    expect(!IndicatorAccessibility.label(for: phase, elapsed: 3).isEmpty, "VoiceOver still hears \(phase.label)")
                }
                fills[phase.label] = IndicatorState.make(phase: phase, isCleaning: false, retryAvailable: false).fill
            }
            expectEqual(fills["Listening"], .red)
            expectEqual(fills["Transcribing"], .blue)
            expectEqual(IndicatorState.make(phase: .pasted, isCleaning: false, retryAvailable: false).fill, .green)
            expectEqual(IndicatorState.make(phase: .transcribing, isCleaning: true, retryAvailable: false).symbol, "wand.and.stars",
                        "cleaning has its own glyph")
            expectEqual(IndicatorState.make(phase: .canceled, isCleaning: false, retryAvailable: false).action, .keep)
            expectEqual(IndicatorState.make(phase: .error("x"), isCleaning: false, retryAvailable: true).action, .retry)
            expectEqual(IndicatorState.make(phase: .error("x"), isCleaning: false, retryAvailable: false).action, nil)
            expectEqual(IndicatorState.symbol(for: .keep), "arrow.uturn.backward")
            expectEqual(IndicatorState.symbol(for: .retry), "arrow.clockwise")
            expectEqual(IndicatorState.make(phase: .recording, isCleaning: false, retryAvailable: false).meter, .live)

            // The reason lives in VoiceOver, not on the bar.
            expectEqual(
                IndicatorAccessibility.value(caption: "TIME LIMIT", badge: nil, phase: .transcribing),
                "time limit"
            )
            expect(IndicatorAccessibility.label(for: .pasted, elapsed: 0).contains("pasted"), "label names the state")
        }

        test("pipeline.hudPositionsIncludeLeftAndRight") {
            expectEqual(HUDPosition.allCases.map(\.rawValue), ["bottom", "top", "left", "right", "off"])
            expectEqual(HUDPosition(configValue: "left"), .left)
            expectEqual(HUDPosition(configValue: "RIGHT"), .right)
            expectEqual(HUDPosition(configValue: "middle"), .bottom, "unknown falls back to bottom")
            expectEqual(HUDPosition.normalized("sideways"), "bottom")
            expect(HUDPosition.left.isVertical && HUDPosition.right.isVertical, "sides are vertical")
            expect(!HUDPosition.bottom.isVertical && !HUDPosition.top.isVertical, "top and bottom are horizontal")
            expect(HUDPosition.left.showsPet && HUDPosition.right.showsPet && HUDPosition.top.showsPet, "the pet lives on every bar")
            expectEqual(HUDPosition.top.petPlacement, .hanging, "under the bar at the top")
            expectEqual(HUDPosition.left.petPlacement, .perched(.leading))
            expect(!HUDPosition.off.showsPet, "no indicator, no pet")
            expect(!HUDPosition.left.showsLivePreview, "no preview strip on a vertical bar")

            let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
            let left = HUDPosition.left.windowOrigin(in: screen)
            let leftSize = HUDPosition.left.windowSize
            expect(leftSize.height > leftSize.width, "vertical window is tall and thin")
            expectEqual(left.x, screen.minX + IndicatorMetrics.edgeInset, "left edge, small inset")
            expectEqual(left.y + IndicatorMetrics.verticalBarArea / 2, screen.midY, "the bar sits in the vertical middle")
            let right = HUDPosition.right.windowOrigin(in: screen)
            expectEqual(right.x + leftSize.width, screen.maxX - IndicatorMetrics.edgeInset, "right edge, small inset")
            expectEqual(right.y + IndicatorMetrics.verticalBarArea / 2, screen.midY)
            let bottom = HUDPosition.bottom.windowOrigin(in: screen)
            expectEqual(bottom.x + HUDPosition.bottom.windowSize.width / 2, screen.midX, "bottom stays centered")
            expectEqual(bottom.y, screen.minY + IndicatorMetrics.edgeInset)
            let top = HUDPosition.top.windowOrigin(in: screen)
            expectEqual(top.y + HUDPosition.top.windowSize.height, screen.maxY - IndicatorMetrics.edgeInset)

            // Config recovery keeps a valid side and repairs an unknown value.
            for (stored, expected) in [("left", "left"), ("right", "right"), ("diagonal", "bottom")] {
                let json = #"{"hudPosition": "\#(stored)"}"#
                let decoded = try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
                expectEqual(decoded?.hudPosition, expected, "decode \(stored)")
                let recovered = ConfigRecovery.decode(data: Data(json.utf8), installDefaults: .defaultConfig, lastSaved: { nil })
                expectEqual(recovered.config.hudPosition, expected, "recover \(stored)")
            }
        }

        test("pipeline.cancelUndoBufferHonorsWindow") {
            let start = Date(timeIntervalSince1970: 1_000)
            let url = URL(fileURLWithPath: "/nonexistent/yappyapp-a.wav")
            var buffer = CancelUndoBuffer()
            expectEqual(buffer.hold(audioURL: url, session: 3, target: nil, at: start), nil)
            expectEqual(buffer.discard(now: start.addingTimeInterval(2), onlyIfExpired: true), nil, "still inside the window")
            let pending = buffer.takeForUndo(now: start.addingTimeInterval(4.9))
            expectEqual(pending?.session, 3)
            expectEqual(pending?.audioURL, url)
            expect(buffer.pending == nil, "undo takes it")

            _ = buffer.hold(audioURL: url, session: 4, target: nil, at: start)
            expect(buffer.takeForUndo(now: start.addingTimeInterval(5.1)) == nil, "too late for undo")
            expectEqual(buffer.discard(now: start.addingTimeInterval(5.1), onlyIfExpired: true), url, "expired file returned for deletion")

            let second = URL(fileURLWithPath: "/nonexistent/yappyapp-b.wav")
            _ = buffer.hold(audioURL: url, session: 5, target: nil, at: start)
            expectEqual(buffer.hold(audioURL: second, session: 6, target: nil, at: start), url, "a newer cancel replaces the old file")
            expectEqual(buffer.discard(now: start, onlyIfExpired: false), second)
        }
    }

    // MARK: - Missing feature 3

    private static func pipelineNotificationTests() {
        test("pipeline.notificationPolicy") {
            expect(!DeliveryNotificationPolicy.shouldNotify(for: .pasted, controlsVisible: false), "confirmed")
            expect(!DeliveryNotificationPolicy.shouldNotify(for: .pastedBestEffort, controlsVisible: false), "best-effort")
            expect(!DeliveryNotificationPolicy.shouldNotify(for: .copiedOnly(.autoPasteOff), controlsVisible: false), "by choice")
            expect(DeliveryNotificationPolicy.shouldNotify(for: .copiedOnly(.focusUnclear), controlsVisible: false), "no field")
            expect(DeliveryNotificationPolicy.shouldNotify(for: .withheld(.secureInputActive), controlsVisible: false), "withheld")
            expect(!DeliveryNotificationPolicy.shouldNotify(for: .withheld(.secureInputActive), controlsVisible: true), "open")

            let hidden = DeliveryNotificationPolicy.notice(for: .copiedOnly(.focusUnclear), transcript: "hello there", showText: false)
            expect(!hidden.body.contains("hello"), "default: no transcript text")
            expectEqual(hidden.copyText, "hello there")
            expect(!hidden.copyIsSensitive, "copy-only is not concealed")

            let shown = DeliveryNotificationPolicy.notice(for: .copiedOnly(.focusUnclear), transcript: "hello there", showText: true)
            expect(shown.body.contains("\"hello there\""), "opt-in shows the text")

            let long = String(repeating: "a", count: 400)
            let preview = DeliveryNotificationPolicy.notice(for: .copiedOnly(.focusUnclear), transcript: long, showText: true)
            expect(preview.body.count < 200, "long text is trimmed")
            expectEqual(preview.copyText, long, "COPY still gets the whole text")

            let failure = DeliveryNotificationPolicy.failureNotice(message: "Transcription timed out.")
            expectEqual(failure.body, "Timed out. Open YappYapp for details.")
            expectEqual(failure.copyText, nil)
            let kept = DeliveryNotificationPolicy.failureNotice(message: "The mic didn't start.", audioKept: true)
            expectEqual(kept.body, "Mic trouble. Your audio is kept. Open YappYapp to retry.")
            // The generic label is the title's job; the body only says what to do.
            expectEqual(DeliveryNotificationPolicy.failureNotice(message: "something odd").body, "Open YappYapp for details.")
            expectEqual(DeliveryNotificationPolicy.sentenceCase("WHISPER TROUBLE"), "Whisper trouble")

            // A success notice reads like a success.
            let pasted = DeliveryNotificationPolicy.notice(for: .pasted, transcript: "x", showText: false)
            expectEqual(pasted.title, "Dictation pasted")
            expectEqual(pasted.body, "Pasted at your cursor.")
            // Every copied-only notice gives the ⌘V action; secure input never claims a copy.
            for reason: ClipboardPasteBlockReason in [.focusUnclear, .accessibilityNotTrusted, .modifiersHeld, .autoPasteOff] {
                let notice = DeliveryNotificationPolicy.notice(for: .copiedOnly(reason), transcript: "x", showText: false)
                expectEqual(notice.title, "Copied, not pasted")
                expect(notice.body.contains("⌘V"), "\(reason) names ⌘V")
            }
            let secure = DeliveryNotificationPolicy.notice(for: .withheld(.secureInputActive), transcript: "x", showText: false)
            expect(!secure.body.contains("⌘V"), "secure input never says ⌘V")
            expect(secure.copyIsSensitive, "secure copy is concealed")
        }

        test("pipeline.pastedSpeedReachesTheIndicator") {
            let pipeline = makePipeline()
            let session = pipeline.sessions.begin(target: nil)
            pipeline.delivery.completeDictation(
                transcript: "fast", session: session, sessionTarget: nil, elapsedLabel: "0.8s", hasPetNews: false
            )
            expectEqual(pipeline.state.phase, .pasted)
            expectEqual(pipeline.state.statusText, "Done in 0.8s. Pasted at your cursor.")
            expectEqual(pipeline.state.pastedElapsedLabel, "0.8s")
            expectEqual(
                HUDPresenter.caption(
                    for: pipeline.state.phase, escCancels: true, countdown: nil, note: nil,
                    pastedIn: pipeline.state.pastedElapsedLabel
                ),
                "DONE IN 0.8S"
            )
            // A cleanup note wins over the speed.
            expectEqual(
                HUDPresenter.caption(for: .pasted, escCancels: true, countdown: nil, note: "AS SPOKEN · CLEANUP TOO SLOW", pastedIn: "0.8s"),
                "AS SPOKEN · CLEANUP TOO SLOW"
            )
            // Paste-last has no timing, so the indicator shows PASTED alone.
            pipeline.delivery.deliver(text: "again", to: nil)
            expectEqual(pipeline.state.pastedElapsedLabel, nil)
        }

        test("pipeline.notifierIsInertInSelfTestAndCopiesFromMemory") {
            expect(!DeliveryNotifier.isAvailable, "never touches UNUserNotificationCenter during --self-test")
            let notifier = DeliveryNotifier()
            var copied: [(String, Bool)] = []
            notifier.onCopy = { copied.append(($0, $1)) }
            notifier.post(DeliveryNotice(title: "t", body: "b", copyText: "ignored", copyIsSensitive: false))
            expect(notifier.rememberedText(for: "any") == nil, "an unavailable notifier stores nothing")

            notifier.remember("kept", sensitive: true, for: "n1")
            notifier.handleAction(DeliveryNotifier.copyActionIdentifier, notificationIdentifier: "n1")
            notifier.handleAction("other", notificationIdentifier: "n1")
            expectEqual(copied.map(\.0), ["kept"])
            expectEqual(copied.first?.1, true)

            for index in 0..<(DeliveryNotifier.retainedCopyLimit + 2) {
                notifier.remember("t\(index)", sensitive: false, for: "id\(index)")
            }
            expect(notifier.rememberedText(for: "n1") == nil, "old entries drop out")
            expect(notifier.rememberedText(for: "id0") == nil, "bounded memory")
            expectEqual(notifier.rememberedText(for: "id\(DeliveryNotifier.retainedCopyLimit + 1)"), "t\(DeliveryNotifier.retainedCopyLimit + 1)")
        }
    }

    // MARK: - YA-14, YA-15, YA-62

    private static func pipelinePasteboardTests() {
        test("pipeline.pasteboardMarkers") {
            expectEqual(PasteboardPrivacy.markerTypes(for: .pasteStaging),
                        [PasteboardPrivacy.transientType, PasteboardPrivacy.autoGeneratedType])
            expectEqual(PasteboardPrivacy.markerTypes(for: .copyOnlyDelivery), [PasteboardPrivacy.autoGeneratedType])
            expectEqual(PasteboardPrivacy.markerTypes(for: .userCopy), [])
            expect(PasteboardPrivacy.markerTypes(for: .sensitiveCopy).contains(PasteboardPrivacy.concealedType),
                   "sensitive copies are concealed")

            // An isolated, uniquely named pasteboard; never the general one.
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let before = pasteboard.changeCount
            let after = PasteboardPrivacy.write("staged words", to: pasteboard, purpose: .pasteStaging)
            expect(after != before, "write bumps the change count")
            expectEqual(pasteboard.string(forType: .string), "staged words")
            let types = Set(pasteboard.types ?? [])
            expect(types.contains(PasteboardPrivacy.transientType), "transient marker written")
            expect(types.contains(PasteboardPrivacy.autoGeneratedType), "auto-generated marker written")

            PasteboardPrivacy.write("mine", to: pasteboard, purpose: .userCopy)
            let userTypes = Set(pasteboard.types ?? [])
            expect(!userTypes.contains(PasteboardPrivacy.transientType), "a user copy is not transient")
            expectEqual(pasteboard.string(forType: .string), "mine")
        }

        test("pipeline.clipboardRestoreSkipsPasswordManagerItems") {
            expect(PasteboardPrivacy.isRestorable(itemTypes: [["public.utf8-plain-text"]]), "plain text restores")
            expect(PasteboardPrivacy.isRestorable(itemTypes: []), "empty restores")
            expect(!PasteboardPrivacy.isRestorable(itemTypes: [["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]]),
                   "concealed is never restored")
            expect(!PasteboardPrivacy.isRestorable(itemTypes: [["public.png"], ["org.nspasteboard.TransientType"]]),
                   "transient in any item blocks the restore")
            // Best-effort still restores when opted in; the status then points to COPY.
            expect(ClipboardInjector.shouldRestoreClipboard(after: .pastedBestEffort),
                   "best-effort restore stays opt-in")
            expect(!ClipboardInjector.shouldRestoreClipboard(after: .copiedOnly(.focusUnclear)),
                   "copy-only never restores")
        }
    }

    // MARK: - YA-20, YA-59, YA-61

    private static func pipelineSystemLookupTests() {
        test("pipeline.commandVFollowsKeyboardLayout") {
            // Dvorak puts "v" on the ANSI period key (0x2F).
            let dvorak: [CGKeyCode: String] = [0x09: "k", 0x2F: "v", 0x00: "a"]
            expectEqual(KeyboardLayoutKeyCode.keyCode(for: "v", translate: { dvorak[$0] }), 0x2F)
            let qwerty: [CGKeyCode: String] = [0x09: "v", 0x2F: "."]
            expectEqual(KeyboardLayoutKeyCode.keyCode(for: "v", translate: { qwerty[$0] }), 0x09)
            expectEqual(KeyboardLayoutKeyCode.keyCode(for: "v", translate: { _ in nil }), nil)
            let live = KeyboardLayoutKeyCode.commandVKeyCode()
            expect(live < 128, "live lookup returns a real virtual key")
            expectEqual(ClipboardInjector.axMessagingTimeout, 0.35)
            expect(ClipboardInjector.axMessagingTimeout >= 0.25 && ClipboardInjector.axMessagingTimeout <= 0.5,
                   "AX timeout within 0.25-0.5s")
        }

        test("pipeline.secureInputOwnerParsesConsoleUsers") {
            expectEqual(SecureInputOwner.pid(fromConsoleUsers: []), nil)
            expectEqual(SecureInputOwner.pid(fromConsoleUsers: [["kCGSSessionUserNameKey": "me"]]), nil)
            expectEqual(SecureInputOwner.pid(fromConsoleUsers: [["kCGSSessionSecureInputPID": NSNumber(value: 0)]]), nil)
            expectEqual(SecureInputOwner.pid(fromConsoleUsers: [
                ["kCGSSessionUserNameKey": "other"],
                ["kCGSSessionSecureInputPID": NSNumber(value: 4321)]
            ]), 4321)
        }
    }

    // MARK: - YA-13

    private static func pipelineTempFileTests() {
        test("pipeline.launchSweepRemovesOnlyStaleYappYappFiles") {
            let directory = try pipelineScratchDirectory("sweep")
            defer { try? FileManager.default.removeItem(at: directory) }
            let now = Date()
            let old = now.addingTimeInterval(-3_600)

            let stale = directory.appendingPathComponent("yappyapp-stale.wav")
            let staleTranscript = directory.appendingPathComponent("yappyapp-transcript-1.txt")
            let fresh = directory.appendingPathComponent("yappyapp-fresh.wav")
            let unrelated = directory.appendingPathComponent("app.yappyapp.YappYapp.501.instance.lock")
            for url in [stale, staleTranscript, fresh, unrelated] {
                try Data("x".utf8).write(to: url)
            }
            for url in [stale, staleTranscript, unrelated] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }

            let removed = TempFileSweeper.sweep(directory: directory, now: now)
            expectEqual(removed, ["yappyapp-stale.wav", "yappyapp-transcript-1.txt"])
            expect(FileManager.default.fileExists(atPath: fresh.path), "fresh files may belong to a running diagnostic")
            expect(FileManager.default.fileExists(atPath: unrelated.path), "the instance lock is never swept")
        }

        test("pipeline.instanceLockIsPerSupportBase") {
            let plain = SingleInstanceGuard.lockFileName(bundleIdentifier: "app.yappyapp.YappYapp", userID: 501, supportBaseOverride: nil)
            expectEqual(plain, "app.yappyapp.YappYapp.501.instance.lock", "the user's own copy keeps the shared lock")
            expectEqual(SingleInstanceGuard.lockFileName(bundleIdentifier: "app.yappyapp.YappYapp", userID: 501, supportBaseOverride: "  "), plain, "a blank override is no override")
            let smokeA = SingleInstanceGuard.lockFileName(bundleIdentifier: "app.yappyapp.YappYapp", userID: 501, supportBaseOverride: "/tmp/a/Application Support")
            let smokeB = SingleInstanceGuard.lockFileName(bundleIdentifier: "app.yappyapp.YappYapp", userID: 501, supportBaseOverride: "/tmp/b/Application Support")
            expect(smokeA != plain && smokeA != smokeB, "each isolated support base gets its own lock")
            expectEqual(smokeA, SingleInstanceGuard.lockFileName(bundleIdentifier: "app.yappyapp.YappYapp", userID: 501, supportBaseOverride: "/tmp/a/Application Support"), "the name is stable")
            expect(smokeA.hasSuffix(".instance.lock") && !smokeA.hasPrefix("yappyapp-"), "the launch sweep never removes it")
        }

        test("pipeline.inFlightAudioDeletedOnQuit") {
            let directory = try pipelineScratchDirectory("inflight")
            defer { try? FileManager.default.removeItem(at: directory) }
            let tracked = InFlightAudioFiles()
            let first = directory.appendingPathComponent("yappyapp-1.wav")
            let second = directory.appendingPathComponent("yappyapp-2.wav")
            try Data("a".utf8).write(to: first)
            try Data("b".utf8).write(to: second)
            tracked.insert(first)
            tracked.insert(second)
            tracked.remove(second)
            expectEqual(tracked.deleteAll(), 1)
            expect(!FileManager.default.fileExists(atPath: first.path), "tracked file deleted")
            expect(FileManager.default.fileExists(atPath: second.path), "untracked file left alone")
            expect(tracked.urls.isEmpty, "registry cleared")
        }
    }

    // MARK: - Config (YA-17, YA-19, notifications)

    private static func pipelineConfigTests() {
        test("pipeline.configDefaultsAndLegacyDecode") {
            let defaults = AppConfig.defaultConfig
            expect(defaults.autoPaste, "auto-paste on by default")
            expect(defaults.escCancelsRecording, "esc cancels by default")
            expect(!defaults.showTextInNotifications, "no text in notifications by default")

            let legacyOff = """
            {"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"",
             "maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":false}
            """
            let decodedOff = try JSONDecoder().decode(AppConfig.self, from: Data(legacyOff.utf8))
            expect(!decodedOff.autoPaste, "the old 'type into the active app' off means auto-paste off")
            expect(decodedOff.escCancelsRecording, "missing esc key decodes to on")
            expect(!decodedOff.showTextInNotifications, "missing notification key decodes to off")

            let legacyOn = legacyOff.replacingOccurrences(of: "\"pasteWhenFocusIsUnclear\":false", with: "\"pasteWhenFocusIsUnclear\":true")
            expect(try JSONDecoder().decode(AppConfig.self, from: Data(legacyOn.utf8)).autoPaste, "legacy on stays on")

            var custom = defaults
            custom.autoPaste = false
            custom.escCancelsRecording = false
            custom.showTextInNotifications = true
            let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(custom))
            expectEqual(roundTrip, custom)
        }
    }
}
#endif
