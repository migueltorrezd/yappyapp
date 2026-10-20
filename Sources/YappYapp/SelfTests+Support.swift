#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "support" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func supportTrackTests() {
        supportMeterTests()
        supportMicCheckCopyTests()
        supportMicCheckControllerTests()
        supportCrashScannerTests()
        supportReportTests()
        supportRenderTests()
    }

    // MARK: - Fakes

    /// Stands in for the microphone. Tracks whether the "mic" is open so the
    /// tests can prove the check never leaves it that way.
    final class FakeMicLevelSource: MicLevelSource, @unchecked Sendable {
        var level: Float = 0
        var failure: Error?
        private(set) var prepared = 0
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var isOpen = false

        func prepare() -> Int {
            prepared += 1
            return prepared
        }

        func start(generation: Int, deviceUID: String?, meterFloor: Float) async throws {
            starts += 1
            if let failure { throw failure }
            isOpen = true
        }

        func stop() {
            stops += 1
            isOpen = false
        }

        var meterLevel: Float { level }
    }

    @MainActor
    final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Lets the controller's start Task run on the main actor.
    private static func spinMainLoop(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func sine(frames: Int, amplitude: Float) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2.0 * Double.pi * 440 * Double(index) / 16_000.0))
        }
    }

    private static func meter(after decibels: [Float]) -> MicLevelMeter {
        var meter = MicLevelMeter()
        for value in decibels { meter.add(decibels: value) }
        return meter
    }

    // MARK: - Meter

    private static func supportMeterTests() {
        test("support.meterReadsFakeBuffers") {
            let speech = MicLevelMeter.decibels(floatSamples: sine(frames: 1_600, amplitude: 0.1))
            let whisper = MicLevelMeter.decibels(floatSamples: sine(frames: 1_600, amplitude: 0.006))
            let room = MicLevelMeter.decibels(floatSamples: sine(frames: 1_600, amplitude: 0.0003))
            let shout = MicLevelMeter.decibels(floatSamples: sine(frames: 1_600, amplitude: 0.95))
            expect(speech > -26 && speech < -20, "normal speech lands near -23 dBFS, got \(speech)")
            expect(whisper > -52 && whisper < -44, "a whisper lands near -47 dBFS, got \(whisper)")
            expect(room < -60, "room noise sits below the floor, got \(room)")
            expect(shout > -4, "a shout lands near clipping, got \(shout)")

            let int16 = sine(frames: 1_600, amplitude: 0.1).map { Int16($0 * 32767) }
            let fromInt16 = MicLevelMeter.decibels(int16Samples: int16)
            expect(abs(fromInt16 - speech) < 0.5, "Int16 and Float32 buffers meter the same, \(fromInt16) vs \(speech)")
            expectEqual(MicLevelMeter.decibels(floatSamples: []), MicLevelMeter.floorDecibels, "an empty buffer reads as the floor")

            expectEqual(meter(after: Array(repeating: speech, count: 20)).verdict(finished: true), .good, "speech is good")
            expectEqual(meter(after: Array(repeating: whisper, count: 20)).verdict(finished: true), .tooQuiet, "a whisper is too quiet")
            expectEqual(meter(after: Array(repeating: room, count: 20)).verdict(finished: true), .nothingHeard, "room noise is nothing heard")
            expectEqual(meter(after: Array(repeating: shout, count: 20)).verdict(finished: true), .tooLoud, "a shout is too loud")
        }

        test("support.meterWaitsAndIgnoresSpikes") {
            expectEqual(meter(after: [-20, -20]).verdict(finished: false), .listening, "two readings are not enough to judge")
            expectEqual(meter(after: [-20, -20]).verdict(finished: true), .nothingHeard, "a check that ends at once heard nothing")
            expectEqual(
                meter(after: Array(repeating: -70, count: 30)).verdict(finished: false),
                .listening,
                "silence while still listening never scolds"
            )
            let spike = meter(after: Array(repeating: -60, count: 20) + [-20] + Array(repeating: -60, count: 5))
            expect(spike.verdict(finished: true) != .good, "one click is not speech")
            expect(spike.loudestDecibels < -38, "smoothing caps a single spike, got \(spike.loudestDecibels)")

            var normalized = MicLevelMeter()
            for _ in 0..<15 { normalized.add(normalizedLevel: 0.5) }
            expect(abs(normalized.loudestDecibels - -30) < 0.01, "a half-scale reading is -30 dBFS on the -60 floor")
            expect(abs(normalized.barLevel - 0.5) < 0.01, "the bar follows the smoothed level")
            normalized.add(decibels: .nan)
            expect(normalized.loudestDecibels.isFinite, "a NaN reading never poisons the meter")
            normalized.reset()
            expectEqual(normalized.readings, 0, "reset clears readings")
        }
    }

    // MARK: - Copy

    private static func supportMicCheckCopyTests() {
        test("support.micCheckCopy") {
            let quietBoostOn = MicCheckCopy.make(phase: .finished, verdict: .tooQuiet, quietVoiceBoost: true)
            expectEqual(quietBoostOn.headline, "TOO QUIET")
            expect(quietBoostOn.detail.contains("Quiet Voice Boost is on and will help"), "boost on says it will help")
            expect(!quietBoostOn.offersBoost, "boost on offers no switch")

            let quietBoostOff = MicCheckCopy.make(phase: .listening, verdict: .tooQuiet, quietVoiceBoost: false)
            expect(quietBoostOff.detail.contains("Turn on Quiet Voice Boost"), "boost off points at the boost")
            expect(quietBoostOff.offersBoost, "boost off offers the switch")

            let good = MicCheckCopy.make(phase: .finished, verdict: .good, quietVoiceBoost: false)
            expectEqual(good.headline, "GOOD")
            expectEqual(good.tone, .good)
            expect(!good.offersBoost, "a good level offers nothing")

            let idle = MicCheckCopy.make(phase: .idle, verdict: .good, quietVoiceBoost: true)
            expectEqual(idle.headline, "6-SECOND MIC TEST")
            expect(idle.headline.hasPrefix("\(Int(MicCheckController.duration))-SECOND"), "the idle title matches the real test length")
            expect(MicCheckCopy.intro.contains("Nothing is saved or transcribed"), "the intro promises nothing is kept")
            expectEqual(MicCheckCopy.failure(for: RecordingError.microphoneDenied), .micBlocked)
            expectEqual(MicCheckCopy.failure(for: RecordingError.recorderUnavailable), .wontOpen)
            expect(
                MicCheckCopy.message(for: .micBlocked, pickerAbove: true).contains("System Settings > Privacy & Security > Microphone"),
                "a blocked mic names the full System Settings path"
            )
            // SETUP-ORDER: in SETUP the picker sits right above the check; the
            // first-run card on MIC points to Setup instead.
            expectEqual(
                MicCheckCopy.make(phase: .failed(.wontOpen), verdict: .good, quietVoiceBoost: true, pickerAbove: true).detail,
                "That mic won't open. Pick another above."
            )
            expect(
                MicCheckCopy.make(phase: .failed(.wontOpen), verdict: .good, quietVoiceBoost: true).detail.contains("Setup > Microphone"),
                "the MIC tab card points to Setup > Microphone"
            )
            expect(
                MicCheckCopy.make(phase: .finished, verdict: .nothingHeard, quietVoiceBoost: false, pickerAbove: true).detail.contains("above"),
                "nothing heard in SETUP points at the picker above"
            )
            expect(
                MicCheckCopy.make(phase: .finished, verdict: .nothingHeard, quietVoiceBoost: false).detail.contains("Setup > Microphone"),
                "nothing heard on MIC points to Setup > Microphone"
            )

            let all: [MicCheckCopy] = [MicLevelVerdict.listening, .nothingHeard, .tooQuiet, .good, .tooLoud].flatMap { verdict in
                [true, false].flatMap { boost in
                    [true, false].map { MicCheckCopy.make(phase: .finished, verdict: verdict, quietVoiceBoost: boost, pickerAbove: $0) }
                }
            }
            expect(all.allSatisfy { !($0.headline + $0.detail).contains("\u{2014}") }, "no em dashes in mic check copy")
        }
    }

    // MARK: - Controller

    private static func supportMicCheckControllerTests() {
        test("support.micCheckRunsAndClosesTheMic") {
            let clock = FakeClock()
            let source = FakeMicLevelSource()
            let check = MicCheckController(makeSource: { source }, now: { clock.now }, schedulesTimer: false)

            check.start(deviceUID: "fake-device")
            expectEqual(check.phase, .starting, "the check starts by opening the mic")
            spinMainLoop { check.phase == .listening }
            expectEqual(check.phase, .listening, "the check listens once the mic is open")
            expect(source.isOpen, "the fake mic is open while listening")
            expectEqual(source.prepared, 1, "the session is authorized before the async start")

            source.level = 0.6 // -24 dBFS: normal speech
            for _ in 0..<12 {
                clock.advance(0.05)
                check.tick()
            }
            expectEqual(check.verdict, .good, "a live verdict appears while listening")
            expect(check.isRunning, "still listening before the time limit")

            clock.advance(MicCheckController.duration)
            check.tick()
            expectEqual(check.phase, .finished, "the check ends by itself")
            expect(!source.isOpen, "the mic is closed when the check ends")
            expectEqual(check.verdict, .good, "the verdict stays on screen")

            let readingsAtFinish = check.meter.readings
            check.tick()
            expectEqual(check.meter.readings, readingsAtFinish, "a finished check reads no more levels")

            check.stop()
            expectEqual(check.phase, .idle, "stop returns to the start")
            expectEqual(check.meter.readings, 0, "stop clears the meter")
        }

        test("support.micCheckWhisperAndManualFinish") {
            let source = FakeMicLevelSource()
            let check = MicCheckController(makeSource: { source }, schedulesTimer: false)
            check.start(deviceUID: nil)
            spinMainLoop { check.phase == .listening }
            source.level = 0.2 // -48 dBFS: a whisper
            for _ in 0..<15 { check.tick() }
            check.finish()
            expectEqual(check.phase, .finished)
            expectEqual(check.verdict, .tooQuiet, "a whisper reads as too quiet")
            expect(check.copy(quietVoiceBoost: false).offersBoost, "the boost is offered when off")
            expect(!source.isOpen, "finish closes the mic")
        }

        test("support.micCheckStopDuringStartNeverLeavesMicOpen") {
            let source = FakeMicLevelSource()
            let check = MicCheckController(makeSource: { source }, schedulesTimer: false)
            check.start(deviceUID: nil)
            check.stop()
            spinMainLoop { source.starts > 0 && source.stops >= 2 }
            expectEqual(check.phase, .idle, "a stop during start wins")
            expect(!source.isOpen, "the late start is closed again")
            expect(source.stops >= 2, "the late start is stopped after it opens")
        }

        test("support.micCheckRestartKeepsTheNewRunOpen") {
            let source = FakeMicLevelSource()
            var made = 0
            let check = MicCheckController(makeSource: { made += 1; return source }, schedulesTimer: false)
            check.start(deviceUID: nil)
            check.stop()
            check.start(deviceUID: nil)
            spinMainLoop { check.phase == .listening && source.starts >= 2 }
            expectEqual(check.phase, .listening, "the newer run goes live")
            expect(source.isOpen, "the stale start never closes the newer run")
            expectEqual(made, 1, "one source serves every run")
            check.stop()
            expect(!source.isOpen, "stop closes it")
        }

        test("support.micCheckFailureIsShownAndClosed") {
            let source = FakeMicLevelSource()
            source.failure = RecordingError.microphoneDenied
            let check = MicCheckController(makeSource: { source }, schedulesTimer: false)
            check.start(deviceUID: nil)
            spinMainLoop { if case .failed = check.phase { return true } else { return false } }
            if case .failed(let failure) = check.phase {
                expectEqual(failure, .micBlocked, "the failure names the cause")
                expect(check.copy(quietVoiceBoost: false).detail.contains("The mic is blocked"), "the card says the mic is blocked")
            } else {
                expect(false, "a failed start shows the failure, got \(check.phase)")
            }
            expect(!check.isRunning, "a failed check is not running")
            expect(!source.isOpen, "a failed start leaves nothing open")
        }

        test("support.micCheckGuidedStep") {
            let check = MicCheckController(makeSource: { FakeMicLevelSource() }, schedulesTimer: false)
            expect(!check.guidedStepArmed, "not armed by default")
            check.armGuidedStep(isFirstRun: true)
            expect(check.guidedStepArmed, "a first-run launch arms the step")
            check.finishGuidedStep()
            expect(!check.guidedStepArmed, "done or skip hides the step")
            check.armGuidedStep(isFirstRun: false)
            expect(!check.guidedStepArmed, "a returning user never sees the step")

            expect(MicCheckController.showsGuidedCard(armed: true, microphoneAuthorized: true, phase: .idle), "shown when armed and allowed")
            expect(!MicCheckController.showsGuidedCard(armed: true, microphoneAuthorized: false, phase: .idle), "hidden until the mic is allowed")
            expect(!MicCheckController.showsGuidedCard(armed: false, microphoneAuthorized: true, phase: .idle), "hidden when not armed")
            expect(!MicCheckController.showsGuidedCard(armed: true, microphoneAuthorized: true, phase: .recording), "hidden while dictating")
            expect(!MicCheckController.showsGuidedCard(armed: true, microphoneAuthorized: true, phase: .transcribing), "hidden while transcribing")
            expect(!MicCheckController.shared.guidedStepArmed, "the shared check is never armed by the self-test")
        }

        test("support.recorderSourceStopWithoutStartIsSafe") {
            // Never started, so no mic opens; stop must still be a no-op.
            let source = RecorderMicLevelSource()
            source.stop()
            source.stop()
            expectEqual(source.meterLevel, 0, "an unopened source reads silence")
        }
    }

    // MARK: - Crash reports

    private static func supportCrashScannerTests() {
        test("support.crashScannerListsOnlyRecentYappYappReports") {
            let directory = temporaryURL("-crashes")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let now = Date(timeIntervalSince1970: 1_800_000_000)
            func make(_ name: String, ageDays: Double) throws {
                let url = directory.appendingPathComponent(name)
                try Data("{}".utf8).write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                    ofItemAtPath: url.path
                )
            }
            try make("YappYapp-2026-10-12-101112.ips", ageDays: 2)
            try make("YappYapp-2026-10-14-090000.ips", ageDays: 1)
            try make("yappyapp-old.crash", ageDays: 5)
            try make("YappYapp-2026-08-01-000000.ips", ageDays: 45)
            try make("Safari-2026-10-12-101112.ips", ageDays: 1)
            try make("YappYapp-notes.txt", ageDays: 1)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("YappYapp-folder.ips"),
                withIntermediateDirectories: true
            )

            let entries = CrashReportScanner.recent(in: directory, now: now)
            expectEqual(
                entries.map(\.name),
                ["YappYapp-2026-10-14-090000.ips", "YappYapp-2026-10-12-101112.ips", "yappyapp-old.crash"],
                "recent YappYapp reports only, newest first"
            )

            for index in 0..<12 {
                try make("YappYapp-bulk-\(index).ips", ageDays: 3 + Double(index) / 10)
            }
            expectEqual(CrashReportScanner.recent(in: directory, now: now).count, CrashReportScanner.limit, "the list is capped")
            expect(
                CrashReportScanner.recent(in: directory.appendingPathComponent("missing"), now: now).isEmpty,
                "a missing folder lists nothing"
            )
        }
    }

    // MARK: - Report

    static func supportReportInput(crashes: [CrashReportEntry] = []) -> SupportReportInput {
        var config = AppConfig.defaultConfig
        config.modelPath = "/Users/alice/Library/Application Support/YappYapp/models/ggml-small.bin"
        config.whisperBinaryPath = "/Users/alice/bin/whisper-cli"
        config.additionalPrompt = "Project Falconridge and Zyxquor Holdings"
        config.inputDeviceUID = "alice-airpods-uid"
        config.quietVoiceBoost = false
        return SupportReportInput(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appVersion: "0.4.0",
            buildNumber: "5",
            bundleIdentifier: "app.yappyapp.YappYapp",
            isPackagedApp: true,
            macOSVersion: "26.1.0",
            architecture: "arm64",
            config: config,
            selectedModelID: "small",
            selectedModelName: "Whisper Small",
            isModelReady: true,
            isWhisperReady: false,
            microphone: "authorized",
            accessibilityTrusted: false,
            staleAccessibilitySuspected: true,
            launchAtLogin: true,
            launchAtLoginNeedsApproval: true,
            managedKeys: ["language", "allowModelDownloads"],
            glossaryEntryCount: 7,
            glossaryLearnedCount: 2,
            neverLearnCount: 3,
            crashReports: crashes,
            homeDirectory: "/Users/alice"
        )
    }

    private static func supportReportTests() {
        test("support.reportIsSanitized") {
            let crash = CrashReportEntry(
                url: URL(fileURLWithPath: "/Users/alice/Library/Logs/DiagnosticReports/YappYapp-2026-10-12-101112.ips"),
                date: Date(timeIntervalSince1970: 1_799_000_000)
            )
            let report = SupportReport.render(supportReportInput(crashes: [crash]))

            expect(report.hasPrefix("# YappYapp Support Report"), "same title as support_report.sh")
            expect(report.contains("- Version: 0.4.0 (5)"), "version and build")
            expect(report.contains("- Selected model: small (Whisper Small)"), "model id")
            expect(report.contains("- Model file: ggml-small.bin"), "model file name only")
            expect(report.contains("- Microphone: authorized"), "microphone permission")
            expect(report.contains("- Accessibility: not trusted"), "accessibility permission")
            expect(report.contains("- Start at login: on (needs approval)"), "login item state")
            expect(report.contains("- Quiet Voice Boost: off"), "settings flags")
            expect(report.contains("- Managed settings: allowModelDownloads, language"), "managed keys, sorted")
            expect(report.contains("- Glossary: 7 entries, 2 learned from fixes (text hidden)"), "glossary count only")
            expect(report.contains("- Learn from my fixes: on"), "learn from fixes flag")
            expect(report.contains("- Never-learn list: 3 words (text hidden)"), "never-learn count only")
            expect(report.contains("- Custom vocabulary prompt: custom (text hidden)"), "prompt flagged, not shown")
            expect(report.contains("- Input device: a specific device (name hidden)"), "device hidden")
            expect(report.contains("- YappYapp-2026-10-12-101112.ips (2027-01-03T18:13:20Z)"), "crash name and date")
            expect(report.contains("- UTC time: 2027-01-15T08:00:00Z"), "UTC timestamp")

            for secret in ["alice", "Falconridge", "Zyxquor", "airpods", "DiagnosticReports"] {
                expect(!report.contains(secret), "the report never contains \(secret)")
            }
            expect(!report.contains("\u{2014}"), "no em dashes in the report")

            let empty = SupportReport.render(supportReportInput())
            expect(empty.contains("None in the last 30 days."), "no crashes says so")
        }

        // INTEGRATION: the wave-2 feature settings show up too, apps hidden.
        test("support.reportListsFeatureSettings") {
            var input = supportReportInput()
            input.config.cleanup = .email
            input.config.spokenCommands = false
            input.config.livePreview = true
            input.config.appProfiles = [AppProfile(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", language: "fr")]
            let report = SupportReport.render(input)
            expect(report.contains("- Cleanup mode: email"), "cleanup mode")
            expect(report.contains("- Spoken commands: off"), "spoken commands")
            expect(report.contains("- Live preview: on"), "live preview")
            expect(report.contains("- Per-app profiles: 1 (apps hidden)"), "profile count only")
            expect(!report.contains("slackmacgap") && !report.contains("Slack"), "profile apps are not listed")
        }

        test("support.reportRedactsPaths") {
            expectEqual(
                SupportReport.redact("a /Users/alice/x and /Users/bob/y", homeDirectory: "/Users/alice"),
                "a ~/x and /Users/<user>/y"
            )
            expectEqual(SupportReport.redact("/Users/alice", homeDirectory: "/Users/alice/"), "~")
            expectEqual(SupportReport.redact("no paths", homeDirectory: ""), "no paths")
            expectEqual(SupportReport.modelFileLabel("parakeet://v3"), "parakeet://v3")
            expectEqual(SupportReport.modelFileLabel("~/models/ggml-base.en.bin"), "ggml-base.en.bin")
            expectEqual(SupportReport.modelFileLabel(""), "none")
            expectEqual(SupportReport.microphoneLabel(authorized: false, denied: true), "denied")
            expectEqual(SupportReport.microphoneLabel(authorized: false, denied: false), "not granted yet")
        }

        test("support.reportFromLiveStateSkipsPrivateText") {
            let directory = temporaryURL("-crash-empty")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let state = makeUIState()
            state.glossaryEntries.append(GlossaryEntry(canonical: "Quorblex", variants: ["quor blex"], notes: "Vexlington team"))
            state.recordTranscript("Remember to call Dr Thistlewood about the merger.")
            state.isMicrophoneAuthorized = true

            let input = SupportReport.currentInput(state: state, crashDirectory: directory)
            expectEqual(input.glossaryEntryCount, state.glossaryEntries.count, "glossary counted")
            expect(input.crashReports.isEmpty, "the injected crash folder is empty")
            let report = SupportReport.render(input)
            for secret in ["quick brown fox", "Thistlewood", "Quorblex", "quor blex", "Vexlington", NSUserName()] where !secret.isEmpty {
                expect(!report.contains(secret), "the report never contains \(secret)")
            }
            expect(report.contains("- Microphone: authorized"), "permission read from state")
            expect(report.contains("- Build type: source build"), "an unbundled self-test is a source build")
        }
    }

    // MARK: - Rendering

    private static func supportRenderTests() {
        test("support.viewsRender") {
            let state = makeUIState()
            state.isMicrophoneAuthorized = true
            var boost = true
            let binding = Binding(get: { boost }, set: { boost = $0 })

            let check = MicCheckController(makeSource: { FakeMicLevelSource() }, schedulesTimer: false)
            check.armGuidedStep(isFirstRun: true)

            let guided = renderImage(
                MicCheckGuidedCard(state: state, quietVoiceBoost: binding, check: check).padding(8),
                width: 420,
                height: 220
            )
            expect(guided != nil, "the guided mic check card renders")

            let settings = renderImage(
                VStack(spacing: 12) {
                    MicCheckSettingsSection(state: state, deviceUID: nil, quietVoiceBoost: binding, check: check)
                    SupportReportSection(state: state, onCopy: { _ in }, onRevealSupport: {}, crashDirectory: nil)
                }
                .padding(8),
                width: 420,
                height: 520
            )
            expect(settings != nil, "the SETUP mic check and support sections render")

            expectEqual(DeveloperLinks.youTube.absoluteString, "https://www.youtube.com/@migueltorrezai")
            expectEqual(DeveloperLinks.linkedIn.absoluteString, "https://www.linkedin.com/in/miguel-torrez")
            var opened: [URL] = []
            let madeBy = renderImage(MadeByGroup(openLink: { opened.append($0) }).padding(8), width: 420, height: 140)
            expect(madeBy != nil, "HELP > MADE BY renders")
            expect(opened.isEmpty, "rendering never opens a link")

            let popover = makeBrutalPopover(state)
            expect(renderImage(popover.settingsTab, width: 404, height: 2_400) != nil, "the SETUP tab still renders")
            expect(renderImage(popover.homeTab, width: 404, height: 900) != nil, "the MIC tab still renders")
        }
    }
}
#endif
