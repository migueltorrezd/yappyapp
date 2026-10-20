#if DEBUG
import AVFoundation
import Foundation
import SwiftUI

// Self-tests owned by the "livefile" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func livefileTrackTests() {
        livePreviewLogicTests()
        livePreviewControllerTests()
        livePreviewConfigTests()
        livePreviewRenderTests()
        fileTranscriptionLogicTests()
        fileTranscriptionConversionTests()
        fileTranscriptionPipelineTests()
        fileTranscriptionCoordinatorTests()
        fileTranscriptionRenderTests()
        fileTranscriptionCleanupModeTests()
    }

    // MARK: - Helpers

    /// Scratch root for this track: under the self-test support base when the
    /// harness sets one, never the user's real folders.
    static func livefileScratch(_ name: String) -> URL {
        let base = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("livefile-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs the main run loop until `condition` holds or the timeout passes.
    @discardableResult
    static func livefileSpin(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Lock-protected result slot for async work awaited by a sync test.
    final class LivefileBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// A decode the test resolves by hand, to hold a decode "in flight".
    final class ManualDecode: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<String?, Never>] = []
        private(set) var calls = 0

        var waiting: Int {
            lock.lock(); defer { lock.unlock() }
            return pending.count
        }

        func decode(_ samples: [Float], _ context: String) async -> String? {
            await withCheckedContinuation { continuation in
                lock.lock()
                calls += 1
                pending.append(continuation)
                lock.unlock()
            }
        }

        func resolveAll(_ text: String?) {
            lock.lock()
            let all = pending
            pending.removeAll()
            lock.unlock()
            all.forEach { $0.resume(returning: text) }
        }
    }

    /// Writes a sine-wave file in any format AVAudioFile can write.
    static func writeSineFile(
        to url: URL,
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        settings: [String: Any]? = nil,
        amplitude: Float = 0.4
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let fileSettings = settings ?? format.settings
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                data[index] = amplitude * Float(sin(2 * Double.pi * 330 * Double(index) / sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    /// 16 kHz mono 16-bit WAV from raw samples.
    static func writeMonoWAV(_ samples: [Int16], to url: URL) throws {
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try writer.append(pcmBytes: data)
        writer.finalize()
    }

    static func tone(seconds: Double, amplitude: Double = 0.3) -> [Int16] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { index in
            Int16(amplitude * 32_767 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }
    }

    static func fakeEngine(
        transcribe: @escaping @Sendable @MainActor (URL, Bool) async throws -> String,
        finished: LivefileBox<Int>? = nil
    ) -> FileTranscriptionEngine {
        FileTranscriptionEngine(
            transcribePart: transcribe,
            cleanup: { $0 },
            finish: { finished?.value = (finished?.value ?? 0) + 1 }
        )
    }

    // MARK: - Live preview

    private static func livePreviewLogicTests() {
        test("livefile.previewTextKeepsTheTail") {
            expectEqual(LivePreviewText.tail("  hello   there  "), "hello there", "short text is only collapsed")
            let long = "the quick brown fox jumps over the lazy dog and keeps running far away from here"
            let tail = LivePreviewText.tail(long)
            expect(tail.hasPrefix("…"), "a cut tail starts with an ellipsis: \(tail)")
            expect(tail.count <= LivePreviewPolicy.characterLimit, "tail fits the limit: \(tail.count)")
            expect(tail.hasSuffix("away from here"), "the newest words stay: \(tail)")
            expect(!tail.dropFirst().hasPrefix(" "), "no space after the ellipsis: \(tail)")
            let words = tail.dropFirst().split(separator: " ")
            expect(long.split(separator: " ").contains(words.first ?? ""), "the first word is whole: \(tail)")
            expectEqual(LivePreviewText.tail(""), "", "empty stays empty")
        }

        test("livefile.previewAudioSkipsSilenceAndLiftsQuietSpeech") {
            expect(LivePreviewAudio.floats(from: []) == nil, "no samples, no decode")
            expect(LivePreviewAudio.floats(from: [Int16](repeating: 3, count: 16_000)) == nil, "silence is skipped")
            let quiet = (0..<16_000).map { Int16(Double(1_000) * sin(Double($0) / 7)) }
            let lifted = LivePreviewAudio.floats(from: quiet)
            expect(lifted != nil, "quiet speech decodes")
            let peak = lifted?.map(abs).max() ?? 0
            expect(peak > 0.5 && peak <= 1, "quiet speech is lifted toward the target peak: \(peak)")
            let loud = [Int16.max, Int16.min, 0]
            let clamped = LivePreviewAudio.floats(from: loud) ?? []
            expect(clamped.allSatisfy { $0 >= -1 && $0 <= 1 }, "floats stay in -1...1")
        }

        test("livefile.previewSchedulerAppliesBackpressure") {
            var scheduler = LivePreviewScheduler()
            let window = LivePreviewPolicy.minimumWindowSamples
            expectEqual(scheduler.decide(totalAppended: 100, windowCount: 100, inFlight: false), .skipTooShort)
            expectEqual(scheduler.decide(totalAppended: 16_000, windowCount: window, inFlight: false), .run)
            expectEqual(scheduler.decide(totalAppended: 20_000, windowCount: window, inFlight: true), .skipInFlight)
            expectEqual(scheduler.skippedInFlight, 1, "in-flight skips are counted")
            expectEqual(
                scheduler.decide(totalAppended: 16_000 + LivePreviewPolicy.minimumNewSamples - 1, windowCount: window, inFlight: false),
                .skipNoNewAudio,
                "too little new audio waits for the next tick"
            )
            expectEqual(
                scheduler.decide(totalAppended: 16_000 + LivePreviewPolicy.minimumNewSamples, windowCount: window, inFlight: false),
                .run
            )
        }

        test("livefile.previewBufferIsCappedAndCounts") {
            let buffer = LivePreviewSampleBuffer(capacity: 4)
            [Int16](arrayLiteral: 1, 2, 3).withUnsafeBufferPointer { buffer.append($0) }
            [Int16](arrayLiteral: 4, 5, 6).withUnsafeBufferPointer { buffer.append($0) }
            let snapshot = buffer.snapshot()
            expectEqual(snapshot.samples, [3, 4, 5, 6], "only the newest window is kept")
            expectEqual(snapshot.totalAppended, 6, "the running total counts every sample")
            buffer.reset()
            expectEqual(buffer.snapshot().samples, [], "reset clears the window")
            expectEqual(buffer.snapshot().totalAppended, 0, "reset clears the total")
            expectEqual(LivePreviewPolicy.windowSamples, LivePreviewPolicy.windowSeconds * 16_000)
        }
    }

    private static func livePreviewControllerTests() {
        test("livefile.previewControllerSkipsTicksWhileDecoding") {
            let manual = ManualDecode()
            var published: [String?] = []
            let controller = LivePreviewController(
                decode: { samples, context in await manual.decode(samples, context) },
                publish: { published.append($0) }
            )
            let buffer = controller.start(context: "v3", useTimer: false)
            expect(controller.isRunning, "start opens a session")
            expectEqual(published, [nil], "a new session clears old text")

            tone(seconds: 1).withUnsafeBufferPointer { buffer.append($0) }
            controller.tick()
            expectEqual(controller.decodesStarted, 1, "the first tick decodes")
            livefileSpin(timeout: 5) { manual.waiting == 1 }
            tone(seconds: 1).withUnsafeBufferPointer { buffer.append($0) }
            controller.tick()
            controller.tick()
            expectEqual(controller.decodesStarted, 1, "no second decode while one is in flight")
            expectEqual(controller.skippedTicks, 2, "both ticks were skipped")

            manual.resolveAll("hello from the preview")
            livefileSpin(timeout: 5) { published.count == 2 }
            expectEqual(published.last ?? nil, "hello from the preview", "the decode result is published")
            expect(!controller.isDecoding, "the in-flight slot frees up")

            controller.tick()
            expectEqual(controller.decodesStarted, 2, "the next tick with new audio decodes again")
            livefileSpin(timeout: 5) { manual.waiting == 1 }

            controller.stop()
            expect(!controller.isRunning, "stop ends the session")
            expectEqual(published.last ?? "x", nil, "stop clears the HUD text at once")
            let countAfterStop = published.count
            manual.resolveAll("late text")
            livefileSpin(timeout: 0.3) { false }
            expectEqual(published.count, countAfterStop, "a decode that finishes after stop is dropped")
            controller.tick()
            expectEqual(controller.decodesStarted, 2, "ticks after stop do nothing")
        }

        test("livefile.previewControllerSkipsSilence") {
            let manual = ManualDecode()
            let controller = LivePreviewController(
                decode: { samples, context in await manual.decode(samples, context) },
                publish: { _ in }
            )
            let buffer = controller.start(context: "v3", useTimer: false)
            [Int16](repeating: 0, count: 16_000).withUnsafeBufferPointer { buffer.append($0) }
            controller.tick()
            expectEqual(controller.decodesStarted, 0, "silence costs no decode")
            controller.stop()
        }
    }

    private static func livePreviewConfigTests() {
        test("livefile.livePreviewConfigIsOptInAndSurvivesRepair") {
            expect(!AppConfig.defaultConfig.livePreview, "live preview is off by default")

            var config = AppConfig.defaultConfig
            config.livePreview = true
            config.modelPath = "parakeet://v3"
            expect(LivePreviewPolicy.isEligible(config: config), "on with Parakeet")
            config.modelPath = "/tmp/ggml-base.en.bin"
            expect(!LivePreviewPolicy.isEligible(config: config), "never with Whisper")
            expect(LivePreviewPolicy.settingsNote(config: config).contains("only with Parakeet"), "the note says why it is off")
            config.livePreview = false
            config.modelPath = "parakeet://v3"
            expect(!LivePreviewPolicy.isEligible(config: config), "off when the user did not turn it on")

            // An older file without the key decodes with the feature off.
            let legacy = try JSONSerialization.data(withJSONObject: [
                "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
                "modelPath": "parakeet://v3",
                "language": "auto",
                "additionalPrompt": "",
                "maxRecordingSeconds": 120,
                "restoreClipboardAfterPaste": true,
                "pasteWhenFocusIsUnclear": false
            ])
            let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
            expect(!decoded.livePreview, "a legacy config keeps live preview off")

            var saved = AppConfig.defaultConfig
            saved.livePreview = true
            let data = try JSONEncoder().encode(saved)
            let roundTrip = try JSONDecoder().decode(AppConfig.self, from: data)
            expect(roundTrip.livePreview, "the setting round-trips")

            let repaired = ConfigRecovery.decode(data: data, installDefaults: .defaultConfig, lastSaved: { nil })
            expect(repaired.config.livePreview, "config repair keeps the live preview setting")
            expectEqual(ConfigRecovery.fieldTypes["livePreview"], .bool, "repair knows the key")

            // A wrong-typed value costs only that value.
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            object["livePreview"] = "yes"
            let damaged = try JSONSerialization.data(withJSONObject: object)
            let fallback = try JSONDecoder().decode(AppConfig.self, from: damaged)
            expect(!fallback.livePreview, "a damaged value falls back to off")
        }
    }

    private static func livePreviewRenderTests() {
        test("livefile.hudShowsLivePreviewOnlyWhileRecording") {
            let state = makeUIState(phase: .recording)
            state.config.pet = "none"
            let without = renderPixelSnapshot(AlwaysOnHUDView(state: state), width: 200, height: 120)
            state.livePreviewText = "hello there"
            let with = renderPixelSnapshot(AlwaysOnHUDView(state: state), width: 200, height: 120)
            expect(without != nil && with != nil, "the HUD renders with and without preview text")
            if let without, let with {
                expect(without.fingerprint != with.fingerprint, "the preview strip changes the HUD")
                // Right end of the strip, above the bar: flat paper.
                let x = Int(Double(with.width) * 170 / 200)
                let y = Int(Double(with.height) * 81 / 120)
                let pixel = with.pixel(x: x, y: y)
                expect(pixel.count == 4 && pixel[0] > 220 && pixel[1] > 220 && pixel[2] > 200,
                       "the strip is a flat paper fill: \(pixel)")
                let empty = without.pixel(x: x, y: y)
                expect(empty.count == 4 && empty[3] == 0, "no strip without preview text: \(empty)")
            }

            state.phase = .transcribing
            let afterStop = renderPixelSnapshot(AlwaysOnHUDView(state: state), width: 200, height: 120)
            if let afterStop {
                let x = Int(Double(afterStop.width) * 170 / 200)
                let y = Int(Double(afterStop.height) * 81 / 120)
                expectEqual(afterStop.pixel(x: x, y: y).last, 0, "the strip hides once recording ends")
            }
            expectEqual(AlwaysOnHUDView.windowSize(for: "bottom").height, 120, "the HUD window has room for the strip")

            // Left and right have no room for a line of words: no strip there.
            for side in ["left", "right"] {
                let vertical = makeUIState(phase: .recording)
                vertical.config.hudPosition = side
                let size = AlwaysOnHUDView.windowSize(for: side)
                let plain = renderPixelSnapshot(AlwaysOnHUDView(state: vertical), width: size.width, height: size.height)
                vertical.livePreviewText = "hello there"
                let withText = renderPixelSnapshot(AlwaysOnHUDView(state: vertical), width: size.width, height: size.height)
                expect(plain != nil && plain?.fingerprint == withText?.fingerprint, "\(side): no preview strip")
            }
        }
    }

    // MARK: - File transcription

    private static func fileTranscriptionLogicTests() {
        test("livefile.fileInputAcceptsCommonAudioAndVideo") {
            for ext in ["wav", "M4A", "mp3", "aiff", "aif", "caf", "mp4", "MOV"] {
                expect(FileTranscriptionInput.accepts(URL(fileURLWithPath: "/tmp/a.\(ext)")), "accepts .\(ext)")
            }
            for ext in ["txt", "pdf", "", "mkv"] {
                expect(!FileTranscriptionInput.accepts(URL(fileURLWithPath: "/tmp/a.\(ext)")), "rejects .\(ext)")
            }
            expect(!FileTranscriptionInput.accepts(URL(string: "https://example.com/a.wav")!), "web URLs are refused")
            expect(FileTranscriptionInput.contentTypes.count >= 7, "the open panel lists every format")
        }

        test("livefile.chunkerCutsAtQuietPoints") {
            let total = 150 * 16_000
            // A quiet dip 3 s before the first 60 s mark.
            let dip = 57 * 16_000
            let ranges = FileTranscriptionChunker.ranges(totalSamples: total) { range in
                abs(range.lowerBound - dip) < 1_600 ? 1 : 1_000
            }
            expect(ranges.count == 3, "150 s splits into 3 parts: \(ranges.count)")
            expectEqual(ranges.first?.lowerBound, 0, "starts at zero")
            expectEqual(ranges.last?.upperBound, total, "ends at the last sample")
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                expectEqual(a.upperBound, b.lowerBound, "parts are contiguous")
            }
            if let first = ranges.first {
                expect(abs(first.upperBound - (dip + 800)) <= 800, "the first cut lands in the dip: \(first.upperBound)")
            }
            expect(ranges.allSatisfy { $0.count <= FileTranscriptionChunker.targetSamples + FileTranscriptionChunker.minimumTailSamples },
                   "no part is much longer than a minute")

            let short = FileTranscriptionChunker.ranges(totalSamples: 62 * 16_000) { _ in 1 }
            expectEqual(short.count, 1, "a short tail rides with the part before it")
            expectEqual(FileTranscriptionChunker.ranges(totalSamples: 0) { _ in 1 }, [], "nothing to cut")
        }

        test("livefile.filePresenterCopy") {
            let converting = FileTranscriptionStatus.running(fileName: "a.m4a", stage: .converting(0.42))
            expectEqual(FileTranscriptionPresenter.headline(for: converting), "TRANSCRIBING FILE")
            expectEqual(FileTranscriptionPresenter.detail(for: converting), "PREPARING 42%")
            let parts = FileTranscriptionStatus.running(fileName: "a.m4a", stage: .transcribing(done: 2, total: 5))
            expectEqual(FileTranscriptionPresenter.detail(for: parts), "PART 3 OF 5")
            let one = FileTranscriptionStatus.running(fileName: "a.m4a", stage: .transcribing(done: 0, total: 1))
            expectEqual(FileTranscriptionPresenter.detail(for: one), "READING THE AUDIO")
            let p1 = FileTranscriptionPresenter.progress(for: converting) ?? -1
            let p2 = FileTranscriptionPresenter.progress(for: parts) ?? -1
            expect(p1 > 0 && p1 < p2 && p2 < 1, "progress grows: \(p1) then \(p2)")
            let done = FileTranscriptionStatus.finished(fileName: "a.m4a", words: 1)
            expectEqual(FileTranscriptionPresenter.detail(for: done), "1 WORD · READY TO COPY OR SAVE")
            expect(FileTranscriptionPresenter.progress(for: done) == nil, "no bar when done")
            expectEqual(FileTranscriptionPresenter.headline(for: .canceled(fileName: "a")), "FILE CANCELED")
            expectEqual(FileTranscriptionPresenter.detail(for: .canceled(fileName: "a")), "NO TRANSCRIPT KEPT")
            expect(FileTranscriptionError.partFailed(part: 2, total: 4, reason: "Timed out.").errorDescription?
                .hasPrefix("Part 2 of 4 failed.") == true, "a failed part is named")
            for text in [
                FileTranscriptionPresenter.detail(for: converting),
                FileTranscriptionError.unsupported.errorDescription ?? "",
                LivePreviewPolicy.settingsNote(config: .defaultConfig)
            ] {
                expect(!text.contains("\u{2014}"), "no em dash in copy: \(text)")
            }
        }
    }

    private static func fileTranscriptionConversionTests() {
        test("livefile.converterMakes16kMonoFromStereoWAVAndAAC") {
            let root = livefileScratch("convert")
            defer { try? FileManager.default.removeItem(at: root) }

            let stereo = root.appendingPathComponent("stereo.wav")
            try writeSineFile(to: stereo, seconds: 2, sampleRate: 44_100, channels: 2)
            let aac = root.appendingPathComponent("speech.m4a")
            try writeSineFile(to: aac, seconds: 2, sampleRate: 44_100, channels: 1, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1
            ])

            for source in [stereo, aac] {
                let destination = root.appendingPathComponent("out-\(source.lastPathComponent).wav")
                let box = LivefileBox<Result<Int, Error>>()
                let progress = LivefileBox<Double>()
                Task.detached {
                    do {
                        let count = try await AudioFileConverter.convert(source: source, destination: destination) {
                            progress.value = $0
                        }
                        box.value = .success(count)
                    } catch {
                        box.value = .failure(error)
                    }
                }
                livefileSpin { box.value != nil }
                switch box.value {
                case .success(let count):
                    expect(abs(count - 32_000) < 2_000, "\(source.pathExtension): ~2 s at 16 kHz, got \(count)")
                    let file = try AVAudioFile(forReading: destination)
                    expectEqual(file.fileFormat.sampleRate, 16_000, "\(source.pathExtension): 16 kHz")
                    expectEqual(file.fileFormat.channelCount, 1, "\(source.pathExtension): mono")
                    let profile = AudioNormalizer.signalProfile(url: destination)
                    expect(profile?.hasMeaningfulSignal == true, "\(source.pathExtension): the tone survives")
                    expect((progress.value ?? 0) > 0.9, "\(source.pathExtension): progress reaches the end")
                case .failure(let error):
                    expect(false, "\(source.pathExtension) conversion failed: \(error)")
                case nil:
                    expect(false, "\(source.pathExtension) conversion timed out")
                }
            }
        }

        test("livefile.converterRefusesNonAudio") {
            let root = livefileScratch("refuse")
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = root.appendingPathComponent("notes.wav")
            try Data("this is not audio".utf8).write(to: fake)
            let box = LivefileBox<Error?>()
            let destination = root.appendingPathComponent("out.wav")
            Task.detached {
                do {
                    _ = try await AudioFileConverter.convert(source: fake, destination: destination) { _ in }
                    box.value = .some(nil)
                } catch {
                    box.value = .some(error)
                }
            }
            livefileSpin { box.value != nil }
            let error = box.value ?? nil
            expect(error is FileTranscriptionError, "a text file is refused with a plain message: \(String(describing: error))")
        }
    }

    private static func fileTranscriptionPipelineTests() {
        test("livefile.pipelineSplitsSkipsSilenceAndDeletesParts") {
            let root = livefileScratch("pipeline")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("talk.wav")
            // 50 s tone, 70 s silence, 30 s tone: three parts, the middle silent.
            try writeMonoWAV(tone(seconds: 50) + [Int16](repeating: 0, count: 70 * 16_000) + tone(seconds: 30), to: source)
            let work = root.appendingPathComponent("work")
            try PrivateFile.ensureDirectory(at: work)

            let calls = LivefileBox<[String]>()
            calls.value = []
            let stages = LivefileBox<[FileTranscriptionStage]>()
            stages.value = []
            let engine = fakeEngine(transcribe: { url, _ in
                expect(FileManager.default.fileExists(atPath: url.path), "the part exists while it is transcribed")
                let index = (calls.value ?? []).count
                calls.value = (calls.value ?? []) + [url.lastPathComponent]
                return "part\(index)"
            })
            let box = LivefileBox<Result<String, Error>>()
            Task.detached {
                do {
                    let text = try await FileTranscriptionPipeline.run(
                        source: source,
                        workDirectory: work,
                        engine: engine,
                        progress: { stage in stages.value = (stages.value ?? []) + [stage] }
                    )
                    box.value = .success(text)
                } catch {
                    box.value = .failure(error)
                }
            }
            livefileSpin(timeout: 30) { box.value != nil }
            switch box.value {
            case .success(let text):
                expectEqual(text, "part0 part1", "two spoken parts are joined; silence is skipped")
                expectEqual(calls.value?.count, 2, "the silent part never reaches the engine")
            case .failure(let error):
                expect(false, "pipeline failed: \(error)")
            case nil:
                expect(false, "pipeline timed out")
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            expect(!leftovers.contains { $0.hasPrefix("part-") }, "parts are deleted as they finish: \(leftovers)")
            let seen = stages.value ?? []
            expect(seen.contains(.transcribing(done: 3, total: 3)), "progress reports the last part done")
            expect(seen.contains { if case .converting = $0 { return true }; return false }, "conversion reports progress")
        }

        test("livefile.pipelineReportsNoSpeechAndFailedParts") {
            let root = livefileScratch("pipeline-errors")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("short.wav")
            try writeMonoWAV(tone(seconds: 3), to: source)

            @MainActor func run(_ engine: FileTranscriptionEngine) -> Error? {
                let work = root.appendingPathComponent("work-\(UUID().uuidString)")
                try? PrivateFile.ensureDirectory(at: work)
                let box = LivefileBox<Error?>()
                Task.detached {
                    do {
                        _ = try await FileTranscriptionPipeline.run(source: source, workDirectory: work, engine: engine, progress: { _ in })
                        box.value = .some(nil)
                    } catch {
                        box.value = .some(error)
                    }
                }
                livefileSpin { box.value != nil }
                return box.value ?? nil
            }

            let noSpeech = run(fakeEngine(transcribe: { _, _ in throw WhisperError.noSpeech }))
            expectEqual(noSpeech as? FileTranscriptionError, .noSpeech, "only hallucinations means no speech")
            let failed = run(fakeEngine(transcribe: { _, _ in throw WhisperError.timedOut }))
            if case .partFailed(let part, let total, _)? = failed as? FileTranscriptionError {
                expectEqual(part, 1, "the failing part is named")
                expectEqual(total, 1)
            } else {
                expect(false, "an engine failure fails the job: \(String(describing: failed))")
            }

            let tiny = root.appendingPathComponent("tiny.wav")
            try writeMonoWAV(tone(seconds: 0.2), to: tiny)
            let work = root.appendingPathComponent("work-tiny")
            try PrivateFile.ensureDirectory(at: work)
            let box = LivefileBox<Error?>()
            let engine = fakeEngine(transcribe: { _, _ in "x" })
            Task.detached {
                do {
                    _ = try await FileTranscriptionPipeline.run(source: tiny, workDirectory: work, engine: engine, progress: { _ in })
                    box.value = .some(nil)
                } catch {
                    box.value = .some(error)
                }
            }
            livefileSpin { box.value != nil }
            expectEqual((box.value ?? nil) as? FileTranscriptionError, .tooShort, "a blip is too short")
        }
    }

    private static func fileTranscriptionCoordinatorTests() {
        test("livefile.coordinatorKeepsResultInFilesOnly") {
            let root = livefileScratch("coordinator")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("memo.m4a")
            try writeSineFile(to: source, seconds: 2, sampleRate: 44_100, channels: 1, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1
            ])
            let temp = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

            let state = YappYappState()
            let statusBefore = state.statusText
            let changeCountBefore = NSPasteboard.general.changeCount
            let finished = LivefileBox<Int>()
            let coordinator = FileTranscriptionCoordinator(
                state: state,
                temporaryRoot: temp,
                makeEngine: { fakeEngine(transcribe: { _, _ in "Meeting notes from the file" }, finished: finished) }
            )

            expectEqual(coordinator.start(url: root.appendingPathComponent("notes.txt")), .unsupported)
            if case .failed(let name, let message)? = state.fileTranscription {
                expectEqual(name, "notes.txt")
                expect(message.contains("WAV"), "the refusal lists the formats: \(message)")
            } else {
                expect(false, "an unsupported file shows a failed card")
            }
            coordinator.dismiss()
            expect(state.fileTranscription == nil, "OK clears the card")

            expectEqual(coordinator.start(url: source), .started)
            expect(state.fileTranscription?.isRunning == true, "the card shows progress at once")
            let jobDirs = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
            expect(jobDirs.count == 1 && jobDirs[0].hasPrefix("yappyapp-file-"), "one private job folder: \(jobDirs)")
            if let dir = jobDirs.first {
                let perms = (try? FileManager.default.attributesOfItem(atPath: temp.appendingPathComponent(dir).path)[.posixPermissions]) as? Int
                expectEqual(perms, 0o700, "the job folder is private")
            }
            expectEqual(coordinator.start(url: source), .busy, "one file at a time")

            livefileSpin(timeout: 20) { !coordinator.isRunning }
            expectEqual(state.fileTranscription, .finished(fileName: "memo.m4a", words: 5))
            // FILES is separate from MIC: the result lives in FILES only.
            expectEqual(NSPasteboard.general.changeCount, changeCountBefore, "a finished file never touches the clipboard")
            expect(state.transcriptHistory.isEmpty, "a file transcript never enters the MIC history")
            expectEqual(state.lastTranscript, "", "or the MIC last transcript")
            expectEqual(state.statusText, statusBefore, "or the MIC status line")
            expect(!state.isProcessing, "and never marks the dictation as processing")
            expect(!state.retryAvailable, "or offers a dictation RETRY")
            expectEqual(state.petStats, PetStats(), "or feeds the pet and stats")
            expectEqual(state.fileResults.map(\.text), ["Meeting notes from the file"], "FILES lists the result")
            expectEqual(state.fileResults.first?.fileName, "memo.m4a")
            expectEqual(state.fileResults.first?.wordCount, 5)
            expectEqual(finished.value, 1, "the engine is released after the job")
            livefileSpin(timeout: 2) {
                ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).isEmpty
            }
            expectEqual((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? ["?"], [], "the temp folder is deleted")
            expectEqual(state.phase, .idle, "a file job never touches the dictation phase")
        }

        test("livefile.coordinatorCancelCopiesNothing") {
            let root = livefileScratch("cancel")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("long.wav")
            try writeMonoWAV(tone(seconds: 4), to: source)
            let temp = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

            let manual = ManualDecode()
            let state = YappYappState()
            let changeCountBefore = NSPasteboard.general.changeCount
            let coordinator = FileTranscriptionCoordinator(
                state: state,
                temporaryRoot: temp,
                makeEngine: {
                    fakeEngine(transcribe: { _, _ in (await manual.decode([], "")) ?? "" })
                }
            )
            coordinator.start(url: source)
            livefileSpin(timeout: 10) { manual.waiting == 1 }
            expectEqual(manual.waiting, 1, "the job is mid-part")
            coordinator.cancel()
            expectEqual(state.fileTranscription, .canceled(fileName: "long.wav"), "CANCEL shows at once")
            expect(!coordinator.isRunning, "a new file can start right away")
            manual.resolveAll("should never be copied")
            livefileSpin(timeout: 2) {
                ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).isEmpty
            }
            expectEqual(NSPasteboard.general.changeCount, changeCountBefore, "a canceled job copies nothing")
            expect(state.transcriptHistory.isEmpty, "and adds nothing to history")
            expect(state.fileResults.isEmpty, "or to FILES results")
            expectEqual(state.fileTranscription, .canceled(fileName: "long.wav"), "the late result does not overwrite CANCELED")
            expectEqual((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? ["?"], [], "the temp folder is deleted after cancel")

            coordinator.shutdown()
            expect(!coordinator.isRunning, "shutdown leaves nothing running")
        }
    }

    // INTEGRATION: file parts use the cleanup track's mode API. Layout modes
    // tidy each ~60 s part as Clean; Verbatim never starts the model.
    private static func fileTranscriptionCleanupModeTests() {
        let spoken = "so um the quarterly numbers look good and we should ship the beta next week after review"

        test("livefile.cleanupFollowsTheSetupMode") {
            for mode in CleanupMode.allCases {
                var config = AppConfig.defaultConfig
                config.cleanup = mode
                expectEqual(FileTranscriptionCleanup.mode(for: config), mode.usesModel ? .clean : .verbatim,
                            "\(mode.rawValue) maps to a per-part mode")
            }
        }

        test("livefile.cleanupRunsOnlyWhenTheModeUsesTheModel") {
            let runs = LivefileBox<Int>()
            runs.value = 0
            let environment = CleanupEnvironment(
                binaryPath: { _ in "/usr/bin/true" },
                modelReady: { true },
                modelPath: { "/tmp/qwen.gguf" },
                run: { _ in
                    runs.value = (runs.value ?? 0) + 1
                    return .launchFailed
                }
            )
            for mode in [CleanupMode.verbatim, .email] {
                var config = AppConfig.defaultConfig
                config.cleanup = mode
                let box = LivefileBox<String>()
                Task.detached {
                    box.value = await FileTranscriptionCleanup.apply(
                        spoken, config: config, glossary: Glossary(entries: []), environment: environment
                    )
                }
                livefileSpin(timeout: 10) { box.value != nil }
                expectEqual(box.value, spoken, "\(mode.rawValue): a failed or skipped run keeps the raw part")
            }
            expectEqual(runs.value, 1, "only the mode that uses the model starts llama.cpp")
        }
    }

    private static func fileTranscriptionRenderTests() {
        test("livefile.filesTabIsItsOwnTab") {
            expectEqual(BrutalTab.allCases, [.home, .files, .models, .words, .pet, .settings], "MIC, FILES, MODELS, WORDS, PET, SETUP")
            expectEqual(BrutalTab.files.rawValue, "FILES")
            expectEqual(FileTranscriptionPresenter.destinationTab, .files, "a dropped or picked file opens FILES")
            expectEqual(FileTranscriptSaver.suggestedName(for: "interview.final.m4a"), "interview.final.txt")
            let state = YappYappState()
            for index in 0..<(YappYappState.fileResultsLimit + 2) {
                state.recordFileResult(fileName: "f\(index).wav", text: "text \(index)")
            }
            expectEqual(state.fileResults.count, YappYappState.fileResultsLimit, "results are capped like history")
            expectEqual(state.fileResults.first?.fileName, "f\(YappYappState.fileResultsLimit + 1).wav", "newest first")
        }

        test("livefile.fileCardRendersEveryState") {
            let statuses: [FileTranscriptionStatus] = [
                .running(fileName: "interview.mov", stage: .converting(0.3)),
                .running(fileName: "interview.mov", stage: .transcribing(done: 1, total: 4)),
                .finished(fileName: "interview.mov", words: 1_204),
                .failed(fileName: "interview.mov", message: "macOS could not read the audio in this file."),
                .canceled(fileName: "interview.mov")
            ]
            var fingerprints = Set<UInt64>()
            for status in statuses {
                let snapshot = renderPixelSnapshot(FileTranscriptionCard(status: status), width: 404, height: 110)
                expect((snapshot?.opaquePixelCount ?? 0) > 1_000, "card renders for \(status)")
                if let snapshot { fingerprints.insert(snapshot.fingerprint) }
            }
            expectEqual(fingerprints.count, statuses.count, "every state looks different")

            // FILES: the job lives on its own tab. MIC no longer shows it.
            let state = makeUIState()
            state.fileTranscription = .running(fileName: "talk.m4a", stage: .transcribing(done: 0, total: 2))
            let home = renderPixelSnapshot(makeBrutalPopover(state).homeTab, width: 404, height: 900)
            let filesRunning = renderPixelSnapshot(makeBrutalPopover(state).filesTab, width: 404, height: 900)
            state.fileTranscription = nil
            let plain = renderPixelSnapshot(makeBrutalPopover(state).homeTab, width: 404, height: 900)
            let filesEmpty = renderPixelSnapshot(makeBrutalPopover(state).filesTab, width: 404, height: 900)
            expect(home != nil && plain != nil, "the MIC tab renders with and without a file job")
            expectEqual(home?.fingerprint, plain?.fingerprint, "the file card no longer shows on the MIC tab")
            expect(filesRunning != nil && filesEmpty != nil, "the FILES tab renders empty and running")
            expect(filesRunning?.fingerprint != filesEmpty?.fingerprint, "the file card shows on the FILES tab")
            state.recordFileResult(fileName: "talk.m4a", text: "Notes from the call")
            let filesDone = renderPixelSnapshot(makeBrutalPopover(state).filesTab, width: 404, height: 900)
            expect(filesDone?.fingerprint != filesEmpty?.fingerprint, "a result row replaces the empty line")
            expect(renderImage(FileTranscriptionDropZone(isBusy: true), width: 404, height: 220) != nil, "the busy drop zone renders")
            expect(renderImage(LivePreviewSettingsNote(config: .defaultConfig), width: 300, height: 20) != nil,
                   "the settings note renders")
        }
    }
}
#endif
