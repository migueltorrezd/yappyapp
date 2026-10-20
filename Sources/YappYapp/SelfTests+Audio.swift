#if DEBUG
@preconcurrency import AVFoundation
import Foundation

// Self-tests owned by the "audio" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func audioTrackTests() {
        warmSessionConcurrencyTests()
        captureRecoveryTests()
        preRollTests()
        chimeTests()
        downmixTests()
        routeChangeVerdictTests()
    }

    // MARK: - YA-04 / YA-22 warm session

    /// Fake warm session: counts live sessions so a leak shows up as more
    /// than one running at once. Never touches a microphone.
    private final class FakeWarmSessionLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var builtValue = 0
        private var runningValue = 0
        private var maxRunningValue = 0
        private var defaultUIDValue: String? = "mic-a"

        var built: Int { lock.lock(); defer { lock.unlock() }; return builtValue }
        var running: Int { lock.lock(); defer { lock.unlock() }; return runningValue }
        var maxRunning: Int { lock.lock(); defer { lock.unlock() }; return maxRunningValue }
        var defaultUID: String? {
            get { lock.lock(); defer { lock.unlock() }; return defaultUIDValue }
            set { lock.lock(); defaultUIDValue = newValue; lock.unlock() }
        }

        func make(requested: String?) -> WarmCaptureSessionHandle {
            // Building a real session takes 100-300ms; a short sleep widens
            // the window two concurrent builds would need to overlap.
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock()
            builtValue += 1
            runningValue += 1
            maxRunningValue = max(maxRunningValue, runningValue)
            let uid = requested ?? defaultUIDValue
            lock.unlock()
            return FakeWarmSession(ledger: self, deviceUID: uid)
        }

        func stopped() {
            lock.lock(); runningValue -= 1; lock.unlock()
        }
    }

    private final class FakeWarmSession: WarmCaptureSessionHandle, @unchecked Sendable {
        private let ledger: FakeWarmSessionLedger
        private let lock = NSLock()
        private var running = true
        let deviceUID: String?

        init(ledger: FakeWarmSessionLedger, deviceUID: String?) {
            self.ledger = ledger
            self.deviceUID = deviceUID
        }

        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        func stop() {
            lock.lock()
            let wasRunning = running
            running = false
            lock.unlock()
            if wasRunning { ledger.stopped() }
        }
    }

    private static func makeFakeWarmRecorder(_ ledger: FakeWarmSessionLedger) -> RecordingController {
        let recorder = RecordingController()
        recorder.warmAuthorizationCheck = { true }
        recorder.systemDefaultInputUID = { ledger.defaultUID }
        recorder.warmSessionFactory = { requested in ledger.make(requested: requested) }
        return recorder
    }

    private static func warmSessionConcurrencyTests() {
        test("audio.warmSession.concurrentRefreshesBuildOne") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                recorder.setWarmMode(enabled: true, preferredDeviceUID: nil)
            }
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 1, "64 concurrent refreshes build exactly one session")
            expectEqual(ledger.running, 1, "one live warm session")
            expectEqual(ledger.maxRunning, 1, "never two warm sessions at once")
            expect(recorder.isWarmSessionRunning, "warm session reported running")

            recorder.setWarmMode(enabled: false, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 0, "turning the mode off stops the session")
            expect(!recorder.isWarmSessionRunning, "warm session reported stopped")
        }

        test("audio.warmSession.interleavedToggleEndsInLastState") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                recorder.setWarmMode(enabled: index % 2 == 0, preferredDeviceUID: index % 3 == 0 ? "mic-b" : nil)
            }
            recorder.setWarmMode(enabled: false, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 0, "a final disable always wins and leaves the mic off")
            expect(ledger.maxRunning <= 1, "never two warm sessions at once")

            recorder.setWarmMode(enabled: true, preferredDeviceUID: "mic-b")
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 1, "re-enable builds one session")
        }

        test("audio.warmSession.deviceChangeRebuilds") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            recorder.setWarmMode(enabled: true, preferredDeviceUID: "mic-a")
            recorder.waitForWarmSessionWork()
            recorder.setWarmMode(enabled: true, preferredDeviceUID: "mic-a")
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 1, "an unchanged refresh is a no-op")

            recorder.setWarmMode(enabled: true, preferredDeviceUID: "mic-b")
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 2, "a new preferred device rebuilds")
            expectEqual(ledger.running, 1, "the old session was stopped")
            recorder.setWarmMode(enabled: false, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
        }

        test("audio.warmSession.followsSystemDefault") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            recorder.setWarmMode(enabled: true, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            recorder.defaultInputDidChange()
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 1, "same default input: no rebuild")

            ledger.defaultUID = "mic-c"
            recorder.defaultInputDidChange()
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 2, "new system default input: rebuilt between dictations")
            expectEqual(ledger.running, 1, "the session on the old default was stopped")
            recorder.setWarmMode(enabled: false, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 0)
        }

        test("audio.warmSession.sleepTurnsMicOff") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            recorder.setWarmMode(enabled: true, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            recorder.handleWillSleep()
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 0, "warm mic is off while the Mac sleeps")
            recorder.handleDidWake()
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.running, 1, "warm mic comes back on wake")
            recorder.setWarmMode(enabled: false, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
        }

        test("audio.warmSession.noPermissionNoSession") {
            let ledger = FakeWarmSessionLedger()
            let recorder = makeFakeWarmRecorder(ledger)
            recorder.warmAuthorizationCheck = { false }
            recorder.setWarmMode(enabled: true, preferredDeviceUID: nil)
            recorder.waitForWarmSessionWork()
            expectEqual(ledger.built, 0, "warm mode never opens the mic without permission")
        }

        test("audio.warmSession.planner") {
            expect(WarmSessionPlanner.needsRebuild(isRunning: false, builtForUID: nil, actualDeviceUID: nil, requestedUID: nil, systemDefaultUID: nil), "not running: build")
            expect(!WarmSessionPlanner.needsRebuild(isRunning: true, builtForUID: "a", actualDeviceUID: "a", requestedUID: "a", systemDefaultUID: "b"), "pinned device ignores the default")
            expect(WarmSessionPlanner.needsRebuild(isRunning: true, builtForUID: "a", actualDeviceUID: "a", requestedUID: "b", systemDefaultUID: nil), "new pinned device")
            expect(WarmSessionPlanner.needsRebuild(isRunning: true, builtForUID: nil, actualDeviceUID: "a", requestedUID: nil, systemDefaultUID: "b"), "default moved")
            expect(!WarmSessionPlanner.needsRebuild(isRunning: true, builtForUID: nil, actualDeviceUID: "a", requestedUID: nil, systemDefaultUID: "a"), "default unchanged")
            expect(!WarmSessionPlanner.needsRebuild(isRunning: true, builtForUID: nil, actualDeviceUID: "a", requestedUID: nil, systemDefaultUID: nil), "unknown default keeps the session")
        }
    }

    // MARK: - YA-21 watchdog and interruption copy

    private static func captureRecoveryTests() {
        test("audio.watchdog.stall") {
            let armed = Date(timeIntervalSince1970: 1_000)
            expect(!CaptureWatchdog.shouldRecover(now: armed.addingTimeInterval(1.9), armedAt: armed, lastBufferAt: armed.addingTimeInterval(0.1)), "recent buffer: alive")
            expect(CaptureWatchdog.shouldRecover(now: armed.addingTimeInterval(2.2), armedAt: armed, lastBufferAt: armed.addingTimeInterval(0.1)), "no buffer for >2s: recover")
            expect(!CaptureWatchdog.shouldRecover(now: armed.addingTimeInterval(1.5), armedAt: armed, lastBufferAt: armed.addingTimeInterval(-5)), "idle-warm buffer counts from arm time")
            expect(!CaptureWatchdog.shouldRecover(now: armed.addingTimeInterval(3.5), armedAt: armed, lastBufferAt: nil), "slow input gets a startup grace")
            expect(CaptureWatchdog.shouldRecover(now: armed.addingTimeInterval(4.5), armedAt: armed, lastBufferAt: nil), "no first buffer at all: recover")
            expectEqual(CaptureWatchdog.stallLimit, 2.0)
        }

        test("audio.interruption.messages") {
            let all: [CaptureInterruption] = [.deviceChanged, .sessionStopped, .stalled, .systemSleep]
            for reason in all {
                expect(reason.message.hasSuffix("Transcribing what it caught."), "honest finish copy: \(reason)")
                expect(!reason.message.contains(";"), "no semicolons: \(reason)")
                expect(!reason.message.contains("\u{2014}"), "no em dash: \(reason)")
            }
            expectEqual(Set(all.map(\.message)).count, all.count, "each reason has its own message")
        }

        test("audio.interruption.idleRecorderStaysQuiet") {
            let recorder = RecordingController()
            var fired = 0
            recorder.onIrrecoverableInterruption = { _ in fired += 1 }
            recorder.handleWillSleep()
            recorder.handleDidWake()
            recorder.waitForWarmSessionWork()
            expectEqual(fired, 0, "sleep without a live recording reports nothing")
        }
    }

    // MARK: - YA-23 pre-roll

    private static func preRollTests() {
        test("audio.preRoll.minimumLengthExcludesPreRoll") {
            let floor = RecordingController.minimumFrames
            let ring = RecordingController.warmRingCapacity
            expect(!RecordingController.shouldKeepRecording(frameCount: ring + floor - 1, preRollFrames: ring), "a full ring plus a tap is still an accidental toggle")
            expect(RecordingController.shouldKeepRecording(frameCount: ring + floor, preRollFrames: ring), "enough post-hotkey audio is kept")
            expect(RecordingController.shouldKeepRecording(frameCount: floor), "cold path unchanged")
        }

        test("audio.preRoll.silenceCheckSkipsPreRoll") {
            let url = temporaryURL(".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
            writer.append(makeBuffer(frames: 24_000, amplitude: 0.05))   // loud ambient pre-roll
            writer.append(makeBuffer(frames: 16_000, amplitude: 0.0001)) // silent after the hotkey
            writer.finalize()

            expect(AudioNormalizer.signalProfile(url: url)?.hasMeaningfulSignal == true, "whole file looks like speech")
            let postHotkey = AudioNormalizer.signalProfile(url: url, skippingLeadingSamples: 24_000)
            expectEqual(postHotkey?.sampleCount, 16_000, "pre-roll excluded from the count")
            expect(postHotkey?.hasMeaningfulSignal == false, "post-hotkey silence is rejected")
            expect(AudioNormalizer.signalProfile(url: url, skippingLeadingSamples: 99_999) == nil, "skipping everything leaves nothing")
        }

        test("audio.preRoll.lastStoppedStartsAtZero") {
            expectEqual(RecordingController().lastStoppedPreRollFrames, 0)
        }
    }

    // MARK: - YA-53 chimes

    private static func chimeTests() {
        test("audio.chime.durations") {
            expect(abs(SoundPlayer.startChimeDuration - 0.29) < 0.000_1, "start chime length")
            expect(abs(SoundPlayer.stopChimeDuration - 0.29) < 0.000_1, "stop chime length")
            let samples = ChimeTrimmer.sampleCount(forChimeDuration: 0.29)
            expect((5_600...5_601).contains(samples), "chime plus latency margin at 16 kHz, got \(samples)")
            expectEqual(ChimeTrimmer.sampleCount(forChimeDuration: 0), 0)
        }

        test("audio.chime.trimmerDropsOnlyTheChime") {
            var trimmer = ChimeTrimmer()
            expectEqual(trimmer.leadingSamplesToDrop(of: 512), 0, "disarmed: nothing dropped")
            trimmer.arm(samples: 1_000)
            expectEqual(trimmer.leadingSamplesToDrop(of: 512), 512)
            expectEqual(trimmer.leadingSamplesToDrop(of: 512), 488, "drops only the remainder")
            expectEqual(trimmer.leadingSamplesToDrop(of: 512), 0, "speech after the chime is kept")
            trimmer.arm(samples: 300)
            trimmer.reset()
            expectEqual(trimmer.leadingSamplesToDrop(of: 512), 0, "reset clears a pending trim")
        }

        test("audio.chime.externalOutputSkipsTrim") {
            // No live writer: arming is a no-op either way, and the call must
            // be safe with no recording.
            let recorder = RecordingController()
            recorder.excludeStartChime(duration: 0.29, chimeReachesMicrophone: false)
            recorder.excludeStartChime(duration: 0.29, chimeReachesMicrophone: true)
            recorder.suppressWarmPreRoll(for: 0.29)
            expectEqual(recorder.lastStoppedPreRollFrames, 0)
        }
    }

    // MARK: - YA-55 downmix

    private static func downmixTests() {
        test("audio.downmix.floatNonInterleaved") {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            buffer.frameLength = 4
            let data = buffer.floatChannelData!
            for frame in 0..<4 {
                data[0][frame] = 0.5
                data[1][frame] = 0   // a silent second channel must not be dropped into
            }
            data[1][3] = 0.5
            let mono = AudioDownmix.monoAverage(of: buffer)
            expectEqual(mono?.format.channelCount, 1)
            expectEqual(mono?.frameLength, 4)
            expectEqual(mono?.floatChannelData?[0][0], 0.25, "average of both channels")
            expectEqual(mono?.floatChannelData?[0][3], 0.5)
        }

        test("audio.downmix.voiceOnChannelTwo") {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
            buffer.frameLength = 3
            let samples = buffer.int16ChannelData![0]
            for frame in 0..<3 {
                samples[frame * 2] = 0           // channel 1 silent
                samples[frame * 2 + 1] = 16_384  // voice on channel 2
            }
            let mono = AudioDownmix.monoAverage(of: buffer)
            expectEqual(mono?.floatChannelData?[0][1], 0.25, "channel 2 speech survives the downmix")
        }

        test("audio.downmix.monoPassesThrough") {
            expect(AudioDownmix.monoAverage(of: makeBuffer(frames: 16, amplitude: 0.1)) == nil, "mono input is left to the converter")
        }
    }

    // MARK: - YA-58 route-change harness

    private static func routeChangeVerdictTests() {
        test("audio.routeChange.verdict") {
            let unproven = RouteChangeVerdict.evaluate(flips: 12, interruptions: 0)
            expectEqual(unproven, .unproven(flips: 12))
            expect(!unproven.line.contains("PASSED"), "zero interruptions never prints PASSED")
            expect(unproven.exitCode != 0, "zero interruptions exits nonzero")

            let passed = RouteChangeVerdict.evaluate(flips: 12, interruptions: 1)
            expect(passed.line.hasPrefix("ROUTE-CHANGE TEST PASSED"), "recovery exercised: pass")
            expectEqual(passed.exitCode, 0)
            expectEqual(RouteChangeVerdict.evaluate(flips: 0, interruptions: 0), .unproven(flips: 0))
        }
    }
}
#endif
