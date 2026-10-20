#if DEBUG
import AppKit
import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

/// Built-in integration suite, run with: swift run YappYapp --self-test
/// (or ./scripts/run_tests.sh). Pure logic also lives in the standalone Swift
/// Testing target. This entire file is excluded from release compilation so
/// the production executable cannot expose the test harness or its fixtures.
@MainActor
enum SelfTests {
    static var failures: [String] = []
    static var passed = 0
    static var currentTest = ""

    // MARK: - Assertions

    static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        line: Int = #line
    ) {
        if condition {
            passed += 1
        } else {
            failures.append("[\(currentTest):\(line)] \(message())")
        }
    }

    static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ context: @autoclosure () -> String = "",
        line: Int = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("[\(currentTest):\(line)] \(context()) expected \(expected), got \(actual)")
        }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        do {
            try body()
        } catch {
            failures.append("[\(name)] threw \(error)")
        }
    }

    // MARK: - Helpers

    static func makeBuffer(frames: Int, amplitude: Float, frequency: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.int16ChannelData![0]
        for index in 0..<frames {
            let value = sin(2.0 * Double.pi * frequency * Double(index) / 16_000.0)
            samples[index] = Int16(value * Double(amplitude) * 32767)
        }
        return buffer
    }

    static func temporaryURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lf-selftest-\(UUID().uuidString)\(suffix)")
    }

    static func withTemporaryApplicationSupportBase(_ body: (URL) throws -> Void) throws {
        let base = temporaryURL("-app-support")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let previous = AppPaths.applicationSupportBaseOverride
        AppPaths.applicationSupportBaseOverride = base
        defer {
            AppPaths.applicationSupportBaseOverride = previous
            try? FileManager.default.removeItem(at: base)
        }

        try body(base)
    }

    static func writeWAV(frames: Int, amplitude: Float) throws -> URL {
        let url = temporaryURL(".wav")
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
        writer.append(makeBuffer(frames: frames, amplitude: amplitude))
        writer.finalize()
        return url
    }

    static func writeChunkedWAV(frames: Int, amplitude: Float) throws -> URL {
        let url = try writeWAV(frames: frames, amplitude: amplitude)
        var data = try Data(contentsOf: url)
        var junk = Data("JUNK".utf8)
        junk.append(contentsOf: littleEndianBytes(UInt32(4)))
        junk.append(contentsOf: [0, 0, 0, 0])
        data.insert(contentsOf: junk, at: 36)
        writeLittleEndian(UInt32(data.count - 8), into: &data, at: 4)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
    }

    static func writeLittleEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
        let bytes = littleEndianBytes(value)
        for index in 0..<4 {
            data[offset + index] = bytes[index]
        }
    }

    // MARK: - WAVFileWriter

    private static func wavWriterTests() {
        test("wav.header") {
            let url = try writeWAV(frames: 16_000, amplitude: 0.5)
            defer { try? FileManager.default.removeItem(at: url) }

            let data = try Data(contentsOf: url)
            expectEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
            expectEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
            expectEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
            expectEqual(String(data: data[36..<40], encoding: .ascii), "data")
            expectEqual(data.count, 44 + 16_000 * 2, "total size")

            let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            expectEqual(Int(dataSize), 16_000 * 2, "data chunk size")

            let riffSize = data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            expectEqual(Int(riffSize), 36 + 16_000 * 2, "riff size")
        }

        test("wav.frameCount") {
            let url = temporaryURL(".wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
            writer.append(makeBuffer(frames: 4_000, amplitude: 0.3))
            writer.append(makeBuffer(frames: 2_000, amplitude: 0.3))
            expectEqual(writer.frameCount, 6_000)
        }

        test("wav.finalizeIdempotentAndBlocksLateAppends") {
            let url = temporaryURL(".wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
            writer.append(makeBuffer(frames: 1_000, amplitude: 0.3))
            writer.finalize()
            writer.finalize()
            writer.append(makeBuffer(frames: 1_000, amplitude: 0.3))

            expectEqual(writer.frameCount, 1_000, "late append must be ignored")
            expectEqual(try Data(contentsOf: url).count, 44 + 1_000 * 2)
        }
    }

    // MARK: - AudioNormalizer

    private static func normalizerTests() {
        test("normalizer.amplifiesQuiet") {
            let url = try writeWAV(frames: 16_000, amplitude: 0.02)
            defer { try? FileManager.default.removeItem(at: url) }

            let sizeBefore = try Data(contentsOf: url).count
            let gain = AudioNormalizer.normalize(url: url)
            expect(gain > 10, "expected large gain for whisper-level audio, got \(gain)")
            expectEqual(try Data(contentsOf: url).count, sizeBefore, "size unchanged")
        }

        test("normalizer.leavesLoudAlone") {
            let url = try writeWAV(frames: 16_000, amplitude: 0.9)
            defer { try? FileManager.default.removeItem(at: url) }
            expectEqual(AudioNormalizer.normalize(url: url), 1)
        }

        test("normalizer.leavesSilenceAlone") {
            let url = try writeWAV(frames: 16_000, amplitude: 0)
            defer { try? FileManager.default.removeItem(at: url) }
            expectEqual(AudioNormalizer.normalize(url: url), 1)
        }

        test("normalizer.classifiesSignal") {
            let quietSpeech = try writeWAV(frames: 16_000, amplitude: 0.001)
            defer { try? FileManager.default.removeItem(at: quietSpeech) }
            expect(AudioNormalizer.signalProfile(url: quietSpeech)?.hasMeaningfulSignal == true, "quiet speech should not be rejected")

            let silence = try writeWAV(frames: 16_000, amplitude: 0.0001)
            defer { try? FileManager.default.removeItem(at: silence) }
            expect(AudioNormalizer.signalProfile(url: silence)?.hasMeaningfulSignal == false, "near-silence should be rejected")
        }

        test("normalizer.skipsTooShort") {
            let url = try writeWAV(frames: 800, amplitude: 0.02)
            defer { try? FileManager.default.removeItem(at: url) }
            expectEqual(AudioNormalizer.normalize(url: url), 1)
        }

        test("normalizer.neverCorruptsSamples") {
            let url = try writeWAV(frames: 16_000, amplitude: 0.02)
            defer { try? FileManager.default.removeItem(at: url) }

            AudioNormalizer.normalize(url: url)
            let data = try Data(contentsOf: url)
            expectEqual(data.count, 44 + 16_000 * 2, "sample count preserved")
        }

        test("normalizer.handlesExtraWAVChunks") {
            let url = try writeChunkedWAV(frames: 16_000, amplitude: 0.02)
            defer { try? FileManager.default.removeItem(at: url) }

            let sizeBefore = try Data(contentsOf: url).count
            let profile = AudioNormalizer.signalProfile(url: url)
            expect(profile?.hasMeaningfulSignal == true, "chunked WAV should still expose samples")
            expect(AudioNormalizer.normalize(url: url) > 1, "chunked WAV should normalize")
            expectEqual(try Data(contentsOf: url).count, sizeBefore, "chunked WAV size unchanged")
        }
    }

    // MARK: - RecordingController

    private static func recordingTests() {
        test("recording.discardsAccidentalToggles") {
            expect(!RecordingController.shouldKeepRecording(frameCount: RecordingController.minimumFrames - 1), "short recording should be discarded")
            expect(RecordingController.shouldKeepRecording(frameCount: RecordingController.minimumFrames), "minimum-length recording should be kept")
        }

        test("recording.routeChangeRecoveryTimings") {
            expectEqual(RecordingController.routeChangeRecoveryDebounce, 0.8)
            expectEqual(RecordingController.routeChangeSilenceTolerance, 0.75)
            // ROUTE-CHANGE-FIX (wiredRouteChange): the AVAudioEngine parking
            // path and its retiredEngineDrainDelay are deleted; the shipped
            // capture-session path drives recovery off these two constants.
            // The old assertion here only checked a hand-maintained `static let
            // capturesRouteChangeObservation = true`, which proved nothing (it
            // could not detect the observers being unwired). The real recovery
            // decision is a pure function, exercised directly below; the live
            // observer wiring is covered at runtime by RouteChangeTest.
            expect(
                !RecordingController.shouldFinishAfterRouteChange(secondsSinceLastBuffer: 0.2),
                "recent buffers mean the route change was harmless"
            )
            expect(
                RecordingController.shouldFinishAfterRouteChange(secondsSinceLastBuffer: 1.0),
                "stale buffers mean the route change stopped capture"
            )
            expect(
                RecordingController.shouldFinishAfterRouteChange(secondsSinceLastBuffer: nil),
                "no buffers after a route change should finish gracefully"
            )
        }

        test("recording.normalizedMeterLevel") {
            let silence = RecordingController.normalizedMeterLevel(rms: 0, meterFloor: -42)
            expectEqual(silence.level, 0)
            expect(silence.decibels <= -99, "digital silence should stay near -100 dBFS, got \(silence.decibels)")

            let speech = RecordingController.normalizedMeterLevel(rms: 0.1, meterFloor: -42)
            expect(speech.level > 0.5 && speech.level < 0.55, "speech-ish RMS should land mid-high, got \(speech.level)")
            expect(speech.decibels > -21 && speech.decibels < -19, "unexpected speech dBFS: \(speech.decibels)")

            let clipped = RecordingController.normalizedMeterLevel(rms: 1, meterFloor: -42)
            expectEqual(clipped.level, 1)
            expectEqual(clipped.decibels, 0)
        }

        // SUPER-FAST-MODE: the warm-mic ring buffer is the piece that prepends
        // pre-hotkey audio; wrap-around ordering bugs here would silently
        // corrupt the start of every dictation, so pin it hard.
        test("recording.warmRingBufferOrdering") {
            var ring = Int16RingBuffer(capacity: 4)
            expectEqual(ring.snapshot(), [], "empty ring snapshots empty")

            ring.append(contentsOf: [1, 2])
            expectEqual(ring.snapshot(), [1, 2], "partial fill keeps order")

            ring.append(contentsOf: [3, 4])
            expectEqual(ring.snapshot(), [1, 2, 3, 4], "exact fill keeps order")

            ring.append(contentsOf: [5])
            expectEqual(ring.snapshot(), [2, 3, 4, 5], "wrap drops oldest first")

            ring.append(contentsOf: [6, 7, 8, 9, 10])
            expectEqual(ring.snapshot(), [7, 8, 9, 10], "overfill keeps only the newest capacity samples")

            ring.removeAll()
            expectEqual(ring.snapshot(), [], "removeAll empties the ring")
            ring.append(contentsOf: [11])
            expectEqual(ring.snapshot(), [11], "ring refills cleanly after removeAll")
        }

        test("recording.warmRingCapacityIsShortAndFixed") {
            // 1.5s at 16 kHz: long enough to rescue a clipped first word,
            // short enough that a warm mic never accumulates meaningful audio.
            expectEqual(RecordingController.warmRingCapacity, 24_000)
        }

        // LLM-CLEANUP: the honesty guard is what keeps an optional LLM stage
        // compatible with the no-lie ethos — a rewrite is only trusted when it
        // still looks like the same dictation. Pin the guard and the output
        // hygiene hard; a regression here silently corrupts pasted text.
        test("llmCleanup.acceptGuard") {
            let original = "so um I think we should ship the beta on tuesday after the standup meeting"
            expect(
                LLMCleaner.accept(original: original, cleaned: "I think we should ship the beta on Tuesday, after the standup meeting."),
                "a normal tidy (fillers dropped, punctuation added) must be accepted"
            )
            expect(!LLMCleaner.accept(original: original, cleaned: ""), "empty output must fall back")
            expect(!LLMCleaner.accept(original: original, cleaned: "   \n"), "whitespace-only output must fall back")
            expect(
                !LLMCleaner.accept(original: original, cleaned: "Ship it."),
                "output collapsed far below the original must fall back (model over-summarized)"
            )
            expect(
                !LLMCleaner.accept(original: original, cleaned: String(repeating: original + " ", count: 3)),
                "output ballooned far past the original must fall back (model rambled or answered)"
            )
            expect(!LLMCleaner.accept(original: "", cleaned: "anything"), "empty original never accepts a rewrite")
        }

        test("llmCleanup.sanitizeStripsArtifacts") {
            expectEqual(LLMCleaner.sanitize("  Hello there.  \n"), "Hello there.")
            expectEqual(LLMCleaner.sanitize("Hello there. [end of text]"), "Hello there.")
            expectEqual(LLMCleaner.sanitize("\"Hello there.\""), "Hello there.")
            expectEqual(LLMCleaner.sanitize("```\nHello there.\n```"), "Hello there.")
            expectEqual(
                LLMCleaner.sanitize("Bonjour, ça va ?"), "Bonjour, ça va ?",
                "non-English text passes through untouched"
            )
        }

        test("llmCleanup.extractsResponseFromCLINoise") {
            // Real llama-cli stdout shape (b9870): banner + help, the echoed
            // `> prompt` line, the response, then a stats footer — all on
            // stdout. Extraction must isolate just the response.
            let fixture = """
            Loading model...\u{20}

            build      : b9870-2d973636e
            model      : /tmp/qwen.gguf

            available commands:
              /exit or Ctrl+C     stop or exit
              /regen              regenerate the last response

            > so um ship the beta on monday no wait tuesday

            Ship the beta on Tuesday.

            [ Prompt: 611.8 t/s | Generation: 180.9 t/s ]

            Exiting...
            """
            expectEqual(
                LLMCleaner.extractResponse(fromCLIOutput: fixture),
                "Ship the beta on Tuesday.",
                "response must be isolated from banner, echo, and stats"
            )
            expectEqual(
                LLMCleaner.extractResponse(fromCLIOutput: "Just text, no CLI noise."),
                "Just text, no CLI noise.",
                "output without an echo line passes through sanitized"
            )
        }

        test("llmCleanup.systemPromptContract") {
            // PROMPT-TUNING LOG: no in-prompt examples (they leak into output
            // and prime translation on a 1.5B model), corrections kept verbatim
            // (small models resolve them to the wrong side), same-language
            // preservation stated explicitly, glossary canonicals surfaced as
            // protected spellings.
            let bare = LLMCleaner.systemPrompt(protectedTerms: [])
            expect(!bare.lowercased().contains("example"), "prompt must not contain examples")
            expect(bare.contains("SAME language"), "prompt must pin the transcript language")
            expect(bare.contains("self-corrections"), "prompt must keep corrections verbatim")
            expect(bare.contains("Protected spellings"), "generic prompt must define protected spellings")
            expect(!bare.contains("YappYapp"), "generic argv-safe prompt must contain no user terms")

            let withTerms = LLMCleaner.systemPrompt(protectedTerms: ["YappYapp", "LUMEX"])
            expect(withTerms.contains("YappYapp, LUMEX"), "glossary canonicals ride along as protected spellings")
            expect(withTerms.contains("Never lowercase, translate, split, or respell it."), "prompt must protect exact glossary spellings")
        }

        test("llmCleanup.glossaryTermsFlowIntoPrompt") {
            let glossary = Glossary(entries: [
                GlossaryEntry(canonical: " YappYapp ", variants: [], notes: nil),
                GlossaryEntry(canonical: "LUMEX", variants: ["lou mex"], notes: nil),
                GlossaryEntry(canonical: "yappyapp", variants: [], notes: nil),
                GlossaryEntry(canonical: "", variants: [], notes: nil)
            ])
            let protectedTerms = LLMCleaner.protectedTerms(from: glossary)
            expectEqual(protectedTerms, ["YappYapp", "LUMEX"])

            let prompt = LLMCleaner.systemPrompt(protectedTerms: protectedTerms)
            expect(prompt.contains("YappYapp, LUMEX"), "configured glossary words must reach the Qwen prompt")
            expect(prompt.contains("preserve every listed"), "prompt must instruct Qwen to keep spellings")

            let input = LLMCleaner.inputPayload(
                transcript: "send this to the team",
                protectedTerms: protectedTerms
            )
            expect(input.contains("Protected spellings: YappYapp, LUMEX"), "terms must travel in stdin payload")
            expect(input.contains("Transcript: send this to the team"), "transcript must travel in stdin payload")
        }

        test("llmCleanup.sensitiveContentNeverEntersArguments") {
            let arguments = LLMCleaner.processArguments(tokenBudget: 128)
            let joined = arguments.joined(separator: " ")
            expect(arguments.contains("/dev/stdin"), "llama input must come from stdin")
            expect(arguments.contains("--log-disable"), "llama prompt logging must be disabled")
            expect(!joined.contains("private transcript"), "transcript must not enter argv")
            expect(!joined.contains("SecretClient"), "glossary terms must not enter argv")
        }

        test("llmCleanup.capitalizeFirst") {
            expectEqual(LLMCleaner.capitalizeFirst("okay, so remind me."), "Okay, so remind me.")
            expectEqual(LLMCleaner.capitalizeFirst("Already fine."), "Already fine.")
            expectEqual(LLMCleaner.capitalizeFirst("éteins la lumière."), "Éteins la lumière.")
            expectEqual(LLMCleaner.capitalizeFirst(""), "")
            expectEqual(LLMCleaner.capitalizeFirst("42 things"), "42 things", "non-letter starts untouched")
        }

        test("llmCleanup.skipsTrivialTranscripts") {
            expect(!LLMCleaner.isWorthCleaning("yes"), "one-word dictations skip the cleanup pass")
            expect(!LLMCleaner.isWorthCleaning("send it to john today"), "short commands skip the cleanup pass")
            expect(
                LLMCleaner.isWorthCleaning("so um I think we should ship the beta on tuesday after standup"),
                "sentence-length dictations are worth cleaning"
            )
        }

        test("config.llmCleanupDefaultsOff") {
            expect(!AppConfig.defaultConfig.llmCleanup, "LLM cleanup is opt-in")
            let legacy = Data("""
            {"whisperBinaryPath":"/usr/local/bin/whisper-cli","modelPath":"/tmp/m.bin","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}
            """.utf8)
            if let decoded = try? JSONDecoder().decode(AppConfig.self, from: legacy) {
                expect(!decoded.llmCleanup, "legacy config without the key must decode to off")
                expectEqual(decoded.llamaBinaryPath, "/opt/homebrew/bin/llama-cli")
            } else {
                expect(false, "legacy config fixture failed to decode")
            }
        }

        test("config.updateChecksDefaultOnAndDecodeOn") {
            // UPDATES: auto-check ships ON with a visible off switch (explicit
            // product decision — honest disclosure over silent staleness), and
            // legacy configs without the key upgrade into checks enabled.
            expect(AppConfig.defaultConfig.automaticUpdateChecks, "update checks default on")
            let legacy = Data("""
            {"whisperBinaryPath":"/usr/local/bin/whisper-cli","modelPath":"/tmp/m.bin","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}
            """.utf8)
            if let decoded = try? JSONDecoder().decode(AppConfig.self, from: legacy) {
                expect(decoded.automaticUpdateChecks, "legacy config decodes to checks on")
            } else {
                expect(false, "legacy config fixture failed to decode")
            }
        }

        test("config.superFastModeDefaultsOff") {
            // SUPER-FAST-MODE is opt-in: a warm mic keeps the macOS orange dot
            // lit whenever the app runs, so privacy-first defaults leave it off
            // and legacy configs without the key must decode to off.
            expect(!AppConfig.defaultConfig.superFastMode, "default config must not warm the mic")
            let legacy = Data("""
            {"whisperBinaryPath":"/usr/local/bin/whisper-cli","modelPath":"/tmp/m.bin","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}
            """.utf8)
            if let decoded = try? JSONDecoder().decode(AppConfig.self, from: legacy) {
                expect(!decoded.superFastMode, "legacy config without the key must decode to off")
            } else {
                expect(false, "legacy config fixture failed to decode")
            }
        }
    }

    // MARK: - FillerWords

    private static func fillerWordsTests() {
        test("fillers.english") {
            expectEqual(
                FillerWords.removing(from: "Um, hello there, uh, this is a test."),
                "Hello there, this is a test."
            )
        }

        test("fillers.french") {
            expectEqual(
                FillerWords.removing(from: "Euh je pense que, euhh, c'est bon."),
                "Je pense que, c'est bon."
            )
        }

        test("fillers.wordBoundaries") {
            expectEqual(FillerWords.removing(from: "This summer um arrived."), "This summer arrived.")
        }

        test("fillers.preservesRealWords") {
            let text = "Ben oui, este proyecto es bueno, eh bien."
            expectEqual(FillerWords.removing(from: text), text)
        }

        test("fillers.onlyFillersFallsBack") {
            expectEqual(FillerWords.removing(from: "Uh."), "Uh.")
            expectEqual(FillerWords.removing(from: "umm, hmm"), "umm, hmm")
        }

        test("fillers.tidyPunctuation") {
            let result = FillerWords.removing(from: "So um , yes")
            expect(!result.contains("  "), "double space in: \(result)")
            expect(!result.contains(" ,"), "space before comma in: \(result)")
        }

        // FIX fillerNewline regression: multi-line dictation must keep its line
        // structure. The old \s{2,} collapse flattened paragraphs into one line
        // whenever filler removal ran.
        test("fillers.preservesNewlines") {
            let input = "First line um here.\nSecond paragraph uh follows.\n\nThird block."
            let result = FillerWords.removing(from: input)
            expectEqual(result, "First line here.\nSecond paragraph follows.\n\nThird block.")
            // Two intact newlines between the second and third block survive.
            expect(result.contains("\n\n"), "blank line between paragraphs must survive: \(result)")
            // Runs of spaces/tabs on a single line still collapse to one space.
            expectEqual(FillerWords.removing(from: "one    two"), "one two")
        }

        // FIX fillerNewline regression (line-FINAL filler): a filler that is the
        // last token on a line must not swallow the following newline and merge
        // the two lines. Distinct from fillers.preservesNewlines, whose fillers
        // sit mid-line. Pins the trailing [ \t]* (not \s*) contract on the match.
        test("fillers.lineFinalFillerKeepsNewline") {
            expectEqual(FillerWords.removing(from: "So um\nNext line"), "So\nNext line")
            expectEqual(
                FillerWords.removing(from: "First line here um\nSecond line uh\nThird"),
                "First line here\nSecond line\nThird"
            )
            // Trailing spaces before the line-final filler still collapse cleanly.
            expectEqual(FillerWords.removing(from: "Done  uh\nAgain"), "Done\nAgain")
        }
    }

    // MARK: - Glossary

    private static func glossaryTests() {
        let glossary = Glossary(entries: [
            GlossaryEntry(canonical: "Genial", variants: ["jenial", "génial studio"], notes: nil),
            GlossaryEntry(canonical: "LUMEX", variants: ["lou mex", "lumex"], notes: nil)
        ])

        test("glossary.caseInsensitive") {
            expectEqual(
                glossary.applyingCorrections(to: "I work at Jenial with LOU MEX."),
                "I work at Genial with LUMEX."
            )
        }

        test("glossary.wordBoundaries") {
            expectEqual(
                glossary.applyingCorrections(to: "jenialism is not jenial"),
                "jenialism is not Genial"
            )
        }

        // YA-36: two-letter variants now fire; one letter and everyday words never do.
        test("glossary.shortVariantsIgnored") {
            let short = Glossary(entries: [GlossaryEntry(canonical: "Yes", variants: ["y", "the"], notes: nil)])
            expectEqual(short.applyingCorrections(to: "y the olde shop"), "y the olde shop")
        }

        // FIX glossaryCasing regression: a case-only variant ("yappyapp" ->
        // "YappYapp") must be corrected. The old caseInsensitiveCompare guard
        // skipped these, silently dropping every casing-only fix.
        test("glossary.caseOnlyVariantIsCorrected") {
            let g = Glossary(entries: [
                GlossaryEntry(canonical: "YappYapp", variants: ["yappyapp"], notes: nil)
            ])
            expectEqual(g.applyingCorrections(to: "I love yappyapp today"),
                        "I love YappYapp today")
            // An EXACT copy of the canonical is still skipped (nothing to fix).
            let same = Glossary(entries: [
                GlossaryEntry(canonical: "YappYapp", variants: ["YappYapp"], notes: nil)
            ])
            expectEqual(same.applyingCorrections(to: "YappYapp rules"), "YappYapp rules")
        }

        // FIX glossaryTemplate regression: the canonical is literal data, not a
        // regex replacement template. A "$"/"\" in the canonical must be inserted
        // verbatim, never interpreted as a capture-group reference ($0/$1) which
        // would corrupt the output.
        test("glossary.canonicalDollarIsLiteral") {
            let g = Glossary(entries: [
                GlossaryEntry(canonical: "A$AP", variants: ["asap rocky"], notes: nil)
            ])
            expectEqual(g.applyingCorrections(to: "call asap rocky now"),
                        "call A$AP now")
            let g2 = Glossary(entries: [
                GlossaryEntry(canonical: #"C:\Temp"#, variants: ["see temp"], notes: nil)
            ])
            expectEqual(g2.applyingCorrections(to: "open see temp please"),
                        #"open C:\Temp please"#)
        }

        test("glossary.promptPrefix") {
            let prefix = glossary.promptPrefix()
            expect(prefix.contains("Genial"), "prefix missing Genial: \(prefix)")
            expect(prefix.contains("LUMEX"), "prefix missing LUMEX: \(prefix)")
        }

        test("glossary.saveLoadRoundTrip") {
            let url = temporaryURL(".json")
            defer { try? FileManager.default.removeItem(at: url) }

            try Glossary.save(glossary.entries, to: url)
            let loaded = try Glossary.load(from: url)
            expectEqual(loaded.entries, glossary.entries)
        }

        test("glossary.saveDropsEmptyCanonicals") {
            let url = temporaryURL(".json")
            defer { try? FileManager.default.removeItem(at: url) }

            try Glossary.save([
                GlossaryEntry(canonical: "  ", variants: ["x"], notes: nil),
                GlossaryEntry(canonical: "Keep", variants: [" a ", ""], notes: nil)
            ], to: url)

            let loaded = try Glossary.load(from: url)
            expectEqual(loaded.entries.count, 1)
            expectEqual(loaded.entries.first?.canonical, "Keep")
            expectEqual(loaded.entries.first?.variants, ["a"])
        }
    }

    // MARK: - AppConfig

    private static func configTests() {
        test("config.legacyDecodesWithDefaults") {
            let legacy = """
            {
              "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
              "modelPath": "~/models/ggml-large-v3-turbo.bin",
              "language": "auto",
              "additionalPrompt": "vocab",
              "maxRecordingSeconds": 300,
              "restoreClipboardAfterPaste": false,
              "pasteWhenFocusIsUnclear": true,
              "appearance": "glass"
            }
            """

            let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
            expect(config.keepModelWarm, "keepModelWarm default")
            expect(config.inputDeviceUID == nil, "inputDeviceUID default")
            expectEqual(config.hudPosition, "bottom")
            expect(config.playSounds, "playSounds default")
            expect(!config.removeFillerWords, "removeFillerWords default")
            expect(!config.translateToEnglish, "translateToEnglish default")
            expectEqual(config.translation, .off, "translation is off by default")
            expect(config.quietVoiceBoost, "quietVoiceBoost default")
            expectEqual(config.pet, "cat")
            expect(config.allowModelDownloads, "allowModelDownloads default")
            // GUIDED-FIRST-RUN: legacy files predate the flag, so the guided
            // wizard must show once for them (default false).
            expect(!config.hasCompletedGuidedSetup, "hasCompletedGuidedSetup default false for legacy config")
        }

        test("config.roundTrip") {
            var config = AppConfig.defaultConfig
            config.language = "fr"
            config.pet = "ghost"
            config.hudPosition = "top"
            config.translation = .fr
            config.translationModelID = .hyMT2Best
            config.inputDeviceUID = "device-123"
            config.allowModelDownloads = false
            config.hasCompletedGuidedSetup = true

            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            expectEqual(decoded, config)
            expect(decoded.hasCompletedGuidedSetup, "guided setup flag survives round trip")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expect(object?["appearance"] == nil, "removed appearance setting is not persisted")
        }

        test("config.defaultUsesYappYappSupportPath") {
            expect(
                // PARAKEET-FIRST: the default model is Parakeet Ultra; whisper
                // paths still live under the support directory when chosen.
                AppConfig.defaultConfig.modelPath == "parakeet://ultra"
                    && AppPaths.defaultModelPath(for: "ggml-large-v3-turbo.bin").contains(
                        AppPaths.usesCustomApplicationSupportBase
                            ? AppPaths.modelsDirectory.path
                            : AppPaths.supportDirectoryToken
                    ),
                "default model path should use the public YappYapp support folder"
            )
        }

        test("config.rewritesLegacySupportPaths") {
            expectEqual(
                AppPaths.rewriteLegacySupportPath(
                    in: "~/Library/Application Support/YappYapp/models/ggml-tiny.en.bin"
                ),
                "~/Library/Application Support/YappYapp/models/ggml-tiny.en.bin"
            )
            expectEqual(
                AppPaths.rewriteLegacySupportPath(
                    in: AppPaths.legacySupportDirectory
                        .appendingPathComponent("models/ggml-tiny.en.bin")
                        .path
                ),
                AppPaths.supportDirectory
                    .appendingPathComponent("models/ggml-tiny.en.bin")
                    .path
            )
        }

        test("config.prepareMigratesLegacySupportFolder") {
            try withTemporaryApplicationSupportBase { _ in
                let store = ConfigStore()
                let legacyModel = AppPaths.legacySupportDirectory
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent("ggml-tiny.en.bin")

                try FileManager.default.createDirectory(
                    at: legacyModel.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("model".utf8).write(to: legacyModel)

                var config = AppConfig.defaultConfig
                config.allowModelDownloads = false
                config.modelPath = "\(AppPaths.legacySupportDirectoryToken)/models/ggml-tiny.en.bin"
                let data = try JSONEncoder().encode(config)
                try data.write(to: AppPaths.legacySupportDirectory.appendingPathComponent("config.json"))
                try Glossary.save(Glossary.defaultEntries, to: AppPaths.legacySupportDirectory.appendingPathComponent("glossary.json"))

                try store.prepareApplicationSupport()

                expect(FileManager.default.fileExists(atPath: AppPaths.supportDirectory.path), "YappYapp support folder created")
                expect(!FileManager.default.fileExists(atPath: AppPaths.legacySupportDirectory.path), "legacy support folder moved")
                expect(
                    FileManager.default.fileExists(atPath: AppPaths.modelsDirectory.appendingPathComponent("ggml-tiny.en.bin").path),
                    "legacy model moved into YappYapp models folder"
                )
                expectEqual(
                    try store.load().modelPath,
                    "\(AppPaths.supportDirectoryToken)/models/ggml-tiny.en.bin"
                )
                expect(!((try store.load()).allowModelDownloads), "offline mode preserved during legacy migration")
            }
        }

        test("config.prepareMergesLegacySupportFolder") {
            try withTemporaryApplicationSupportBase { _ in
                let store = ConfigStore()
                try FileManager.default.createDirectory(
                    at: AppPaths.supportDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: AppPaths.legacySupportDirectory,
                    withIntermediateDirectories: true
                )

                var config = AppConfig.defaultConfig
                config.language = "fr"
                config.allowModelDownloads = false
                config.modelPath = AppPaths.legacySupportDirectory
                    .appendingPathComponent("models/ggml-small.bin")
                    .path
                let data = try JSONEncoder().encode(config)
                try data.write(to: AppPaths.configURL)

                let legacyModel = AppPaths.legacySupportDirectory
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent("ggml-small.bin")
                try FileManager.default.createDirectory(
                    at: legacyModel.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("model".utf8).write(to: legacyModel)
                try Glossary.save(Glossary.defaultEntries, to: AppPaths.legacySupportDirectory.appendingPathComponent("glossary.json"))

                try store.prepareApplicationSupport()

                let loaded = try store.load()
                expectEqual(loaded.language, "fr", "existing YappYapp config preserved")
                expectEqual(
                    loaded.modelPath,
                    AppPaths.supportDirectory
                        .appendingPathComponent("models/ggml-small.bin")
                        .path
                )
                expect(!loaded.allowModelDownloads, "offline mode preserved during mixed-folder merge")
                expect(
                    FileManager.default.fileExists(atPath: AppPaths.modelsDirectory.appendingPathComponent("ggml-small.bin").path),
                    "legacy model merged into existing YappYapp folder"
                )
                expect(FileManager.default.fileExists(atPath: AppPaths.glossaryURL.path), "legacy glossary merged")
            }
        }

        test("config.preparePreservesOfflineManagedInstall") {
            try withTemporaryApplicationSupportBase { _ in
                let store = ConfigStore()
                try store.prepareApplicationSupport()

                let managedModel = AppPaths.modelsDirectory.appendingPathComponent("ggml-tiny.en.bin")
                try Data("managed model".utf8).write(to: managedModel)

                var config = try store.load()
                config.allowModelDownloads = false
                config.modelPath = managedModel.path
                try store.save(config)

                try store.prepareApplicationSupport()

                let loaded = try store.load()
                expect(!loaded.allowModelDownloads, "offline mode survives first-launch preparation")
                expectEqual(loaded.modelPath, managedModel.path, "managed model path preserved")
                expect(
                    FileManager.default.fileExists(atPath: managedModel.path),
                    "managed local model remains installed"
                )
            }
        }

        test("config.privateFilesUseOwnerOnlyPermissions") {
            try withTemporaryApplicationSupportBase { _ in
                let store = ConfigStore()
                try store.prepareApplicationSupport()
                try store.save(.defaultConfig)
                try Glossary.save(Glossary.defaultEntries, to: AppPaths.glossaryURL)

                func permissions(at url: URL) throws -> Int {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let raw = attributes[.posixPermissions] as? NSNumber
                    return raw?.intValue ?? -1
                }

                expectEqual(try permissions(at: AppPaths.supportDirectory) & 0o777, 0o700)
                expectEqual(try permissions(at: AppPaths.modelsDirectory) & 0o777, 0o700)
                expectEqual(try permissions(at: AppPaths.configURL) & 0o777, 0o600)
                expectEqual(try permissions(at: AppPaths.glossaryURL) & 0o777, 0o600)
            }
        }
    }

    // MARK: - Brutalist design system

    private static func brutalDesignSystemTests() {
        test("brutal.semanticTextRolesMeetWCAGAA") {
            let pairs: [(String, Color, Color)] = [
                ("primary on card", Brutal.textPrimary, Brutal.card),
                ("secondary on card", Brutal.textSecondary, Brutal.card),
                ("tertiary on card", Brutal.textTertiary, Brutal.card),
                ("danger on card", Brutal.dangerText, Brutal.card),
                ("success on card", Brutal.successText, Brutal.card),
                ("content on yellow", Brutal.contentOnYellow, Brutal.yellow),
                ("content on red", Brutal.contentOnRed, Brutal.red),
                ("content on blue", Brutal.contentOnBlue, Brutal.blue),
                ("content on green", Brutal.contentOnGreen, Brutal.green),
                ("paper on ink", Brutal.paper, Brutal.ink),
                ("success on ink", Brutal.successOnInk, Brutal.ink)
            ]

            for (name, foreground, background) in pairs {
                let ratio = contrastRatio(foreground: foreground, background: background)
                expect(ratio >= 4.5, "\(name) contrast \(String(format: "%.2f", ratio)):1 is below 4.5:1")
            }
        }
    }

    static func contrastRatio(foreground: Color, background: Color) -> Double {
        guard let foreground = NSColor(foreground).usingColorSpace(.sRGB),
              let background = NSColor(background).usingColorSpace(.sRGB) else {
            return 0
        }

        let alpha = foreground.alphaComponent
        let red = foreground.redComponent * alpha + background.redComponent * (1 - alpha)
        let green = foreground.greenComponent * alpha + background.greenComponent * (1 - alpha)
        let blue = foreground.blueComponent * alpha + background.blueComponent * (1 - alpha)
        let foregroundLuminance = relativeLuminance(red: red, green: green, blue: blue)
        let backgroundLuminance = relativeLuminance(
            red: background.redComponent,
            green: background.greenComponent,
            blue: background.blueComponent
        )
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> Double {
        func linearize(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    // MARK: - LanguageCatalog

    private static func languageCatalogTests() {
        test("languageCatalog.sharedCodesAndLabels") {
            expectEqual(LanguageCatalog.options.map(\.code), ["auto", "en", "fr", "es", "nl"])
            expectEqual(LanguageCatalog.options.map(\.menuLabel), ["Auto-Detect", "English", "Français", "Español", "Nederlands"])
            expectEqual(LanguageCatalog.options.map(\.compactLabel), ["Auto", "EN", "FR", "ES", "NL"])
            expectEqual(LanguageCatalog.options.map(\.brutalLabel), ["AUTO", "EN", "FR", "ES", "NL"])
        }

        test("languageCatalog.menuLookup") {
            expectEqual(LanguageCatalog.menuLabel(for: "fr"), "Français")
            expectEqual(LanguageCatalog.menuLabel(for: "zz"), nil)
        }
    }

    // MARK: - PermissionDiagnostics

    private static func permissionDiagnosticsTests() {
        test("permissionDiagnostics.microphoneStatusLabels") {
            expectEqual(PermissionDiagnostics.microphoneStatusLabel(.authorized), "authorized")
            expectEqual(PermissionDiagnostics.microphoneStatusLabel(.denied), "denied")
            expectEqual(PermissionDiagnostics.microphoneStatusLabel(.restricted), "restricted")
            expectEqual(PermissionDiagnostics.microphoneStatusLabel(.notDetermined), "notDetermined")
        }
    }

    // MARK: - ClipboardInjector

    private static func clipboardTests() {
        test("clipboard.classifiesPasteTargets") {
            expectEqual(ClipboardInjector.targetKind(for: "com.apple.Terminal"), .terminal)
            expectEqual(ClipboardInjector.targetKind(for: "com.mitchellh.ghostty"), .terminal)
            expectEqual(ClipboardInjector.targetKind(for: "com.google.Chrome"), .browser)
            expectEqual(ClipboardInjector.targetKind(for: "com.brave.Browser"), .browser)
            expectEqual(ClipboardInjector.targetKind(for: "notion.id"), .webViewApp)
            expectEqual(ClipboardInjector.targetKind(for: "com.tinyspeck.slackmacgap"), .webViewApp)
            // FIX(electronDoubleInsert): the Claude desktop app is Electron —
            // AX writes double-insert and smear placeholder text there, so it
            // must classify as webViewApp and take the Cmd+V path.
            expectEqual(ClipboardInjector.targetKind(for: "com.anthropic.claudefordesktop"), .webViewApp)
            expectEqual(ClipboardInjector.targetKind(for: "net.whatsapp.WhatsApp"), .webViewApp)
            expectEqual(ClipboardInjector.targetKind(for: "com.apple.TextEdit"), .native)
            expectEqual(ClipboardInjector.targetKind(for: nil), .native)
        }

        test("clipboard.blocksWhenPermissionOrSecureInputIsUnsafe") {
            let missingPermission = ClipboardInjector.pasteDecision(
                accessibilityTrusted: false,
                secureInputActive: false,
                targetKind: .native,
                directAccessibilitySucceeded: true,
                foundEditableField: true,
                pasteWhenFocusIsUnclear: true
            )
            expectEqual(missingPermission, .copyOnly(.accessibilityNotTrusted))

            let secureInput = ClipboardInjector.pasteDecision(
                accessibilityTrusted: true,
                secureInputActive: true,
                targetKind: .browser,
                directAccessibilitySucceeded: false,
                foundEditableField: true,
                pasteWhenFocusIsUnclear: true
            )
            // HONEST-PASTE-CONFIRM: secure input must WITHHOLD (copy nothing), not
            // copy-only. This mirrors the runtime, which returns .withheld and never
            // stages the transcript on the shared clipboard for a secure field.
            expectEqual(secureInput, .withhold(.secureInputActive))
        }

        // FIX clipDestroy / copy-only-restore regression. Two pure decisions:
        //  1. A clipboard restore is scheduled ONLY for outcomes that actually
        //     inserted text; copy-only / withheld outcomes leave the transcript
        //     on the clipboard as the deliverable and must never be restored.
        //  2. The deferred restore only fires while the clipboard still carries
        //     OUR write (changeCount unchanged); a newer changeCount means the
        //     user copied something and we must not clobber it.
        test("clipboard.copyOnlyOutcomesNeverScheduleRestore") {
            // Insertion happened + user opted in => restore.
            expect(ClipboardInjector.shouldRestoreClipboard(after: .pasted),
                   "verified paste with restore-on must restore")
            expect(ClipboardInjector.shouldRestoreClipboard(after: .pastedBestEffort),
                   "best-effort paste with restore-on must restore")
            // Copy-only / withheld => the copy is the deliverable, never restore.
            expect(!ClipboardInjector.shouldRestoreClipboard(after: .copiedOnly(.focusUnclear)),
                   "copy-only outcome must not restore even with restore-on")
            expect(!ClipboardInjector.shouldRestoreClipboard(after: .copiedOnly(.modifiersHeld)),
                   "modifiers-held copy-only must not restore")
            expect(!ClipboardInjector.shouldRestoreClipboard(after: .withheld(.secureInputActive)),
                   "withheld (nothing copied) must not restore")
            // CLIPBOARD (0.4.0): no switch turns this off any more. An old
            // config that stored false still restores after a paste.
            let stored = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"restoreClipboardAfterPaste":false}"#.utf8))
            expect(stored.restoreClipboardAfterPaste, "a stored false is ignored: the clipboard always comes back")
            let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
            expectEqual(written?["restoreClipboardAfterPaste"] as? Bool, true, "the key is still written for older builds, always true")
        }

        test("clipboard.restoreGuardsOnChangeCount") {
            expect(ClipboardInjector.clipboardRestoreIsSafe(currentChangeCount: 42, expectedChangeCount: 42),
                   "unchanged clipboard is safe to restore")
            expect(!ClipboardInjector.clipboardRestoreIsSafe(currentChangeCount: 43, expectedChangeCount: 42),
                   "a newer changeCount means the user copied something; do not clobber it")
        }

        test("clipboard.forcesPasteEventsForWebLikeTargets") {
            for kind in [ClipboardPasteTargetKind.browser, .terminal, .webViewApp] {
                let decision = ClipboardInjector.pasteDecision(
                    accessibilityTrusted: true,
                    secureInputActive: false,
                    targetKind: kind,
                    directAccessibilitySucceeded: true,
                    foundEditableField: false,
                    pasteWhenFocusIsUnclear: false
                )

                expectEqual(decision, .commandV, "\(kind) must receive a real paste event")
            }
        }

        test("clipboard.nativeTargetsUseAccessibilityThenSafeFallback") {
            let directInsertion = ClipboardInjector.pasteDecision(
                accessibilityTrusted: true,
                secureInputActive: false,
                targetKind: .native,
                directAccessibilitySucceeded: true,
                foundEditableField: false,
                pasteWhenFocusIsUnclear: false
            )
            expectEqual(directInsertion, .directAccessibility)

            let editableFallback = ClipboardInjector.pasteDecision(
                accessibilityTrusted: true,
                secureInputActive: false,
                targetKind: .native,
                directAccessibilitySucceeded: false,
                foundEditableField: true,
                pasteWhenFocusIsUnclear: false
            )
            expectEqual(editableFallback, .commandV)

            let unclearAllowed = ClipboardInjector.pasteDecision(
                accessibilityTrusted: true,
                secureInputActive: false,
                targetKind: .native,
                directAccessibilitySucceeded: false,
                foundEditableField: false,
                pasteWhenFocusIsUnclear: true
            )
            expectEqual(unclearAllowed, .commandV)

            let unclearBlocked = ClipboardInjector.pasteDecision(
                accessibilityTrusted: true,
                secureInputActive: false,
                targetKind: .native,
                directAccessibilitySucceeded: false,
                foundEditableField: false,
                pasteWhenFocusIsUnclear: false
            )
            expectEqual(unclearBlocked, .copyOnly(.focusUnclear))
        }

        test("clipboard.ignoresUnexpectedAccessibilityValueTypes") {
            expect(
                ClipboardInjector.axElement(fromAccessibilityValue: kCFBooleanTrue) == nil,
                "non-AX values should not be bridged into AXUIElement"
            )
            expect(
                ClipboardInjector.axElement(fromAccessibilityValue: AXUIElementCreateSystemWide()) != nil,
                "system-wide AX element should bridge after type-id validation"
            )

            var selectedRange = CFRange(location: 3, length: 4)
            let rangeValue = AXValueCreate(.cfRange, &selectedRange)
            let extractedRange = ClipboardInjector.selectedTextRange(
                fromAccessibilityValue: rangeValue,
                fallbackLocation: 12
            )
            expectEqual(extractedRange.location, 3)
            expectEqual(extractedRange.length, 4)

            let fallbackRange = ClipboardInjector.selectedTextRange(
                fromAccessibilityValue: kCFBooleanTrue,
                fallbackLocation: 12
            )
            expectEqual(fallbackRange.location, 12)
            expectEqual(fallbackRange.length, 0)
        }
    }

    // MARK: - PasteOutcomePresenter

    private static func pasteOutcomePresenterTests() {
        test("pastePresenter.successStatuses") {
            expectEqual(
                PasteOutcomePresenter.copiedStatus(),
                PasteStatusSnapshot(phase: .copied, statusText: "Copied to the clipboard.")
            )
            expectEqual(
                PasteOutcomePresenter.status(for: .pasted),
                PasteStatusSnapshot(phase: .pasted, statusText: "Pasted at your cursor.")
            )
            expectEqual(
                PasteOutcomePresenter.status(for: .pasted, elapsedLabel: "1.4s"),
                PasteStatusSnapshot(phase: .pasted, statusText: "Done in 1.4s. Pasted at your cursor.")
            )
            // HONEST-PASTE-CONFIRM + YA-03: best-effort uses its own PASTED? phase
            // (no confirmed checkmark) and never reuses the "Pasted" copy.
            expectEqual(
                PasteOutcomePresenter.status(for: .pastedBestEffort),
                PasteStatusSnapshot(phase: .sentUnconfirmed, statusText: "Pasted, but the app didn't confirm. Nothing there? Press ⌘V.")
            )
            expectEqual(
                PasteOutcomePresenter.status(for: .pastedBestEffort, elapsedLabel: "1.4s"),
                PasteStatusSnapshot(phase: .sentUnconfirmed, statusText: "Done in 1.4s. Pasted, but the app didn't confirm. Nothing there? Press ⌘V.")
            )
        }

        test("pastePresenter.copyOnlyReasons") {
            expectEqual(
                PasteOutcomePresenter.status(for: .copiedOnly(.accessibilityNotTrusted)),
                PasteStatusSnapshot(
                    phase: .notDelivered(headline: "COPIED ONLY", reason: "AUTO-PASTE NOT ALLOWED · ⌘V TO PASTE"),
                    statusText: "Auto-paste isn't allowed yet. Press ⌘V to paste."
                )
            )
            expectEqual(
                PasteOutcomePresenter.status(for: .copiedOnly(.secureInputActive)),
                PasteStatusSnapshot(
                    phase: .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT · TEXT KEPT"),
                    statusText: "Secure input is on (a password field or a secure terminal). Your text is safe in HISTORY: press COPY."
                )
            )
            expectEqual(
                PasteOutcomePresenter.status(for: .copiedOnly(.focusUnclear)),
                PasteStatusSnapshot(
                    phase: .notDelivered(headline: "COPIED ONLY", reason: "NO TEXT FIELD · ⌘V TO PASTE"),
                    statusText: "No text field had focus. Press ⌘V where you want it."
                )
            )
        }

        // HONEST-PASTE-CONFIRM: withheld outcomes copy NOTHING, so their wording
        // must never tell the user to press Cmd+V (nothing is on the clipboard).
        test("pastePresenter.withheldReasonsNeverPromiseClipboardPaste") {
            for reason: ClipboardPasteBlockReason in [
                .secureInputActive, .accessibilityNotTrusted, .focusUnclear, .modifiersHeld
            ] {
                let snapshot = PasteOutcomePresenter.status(for: .withheld(reason))
                expectEqual(snapshot.phase, .notDelivered(
                    headline: "NOT PASTED",
                    reason: PasteOutcomePresenter.hudReason(for: reason, copied: false)
                ))
                expect(!snapshot.statusText.contains("Cmd+V"),
                       "withheld(\(reason)) must not tell the user to press Cmd+V")
                expect(!snapshot.statusText.contains("on the clipboard"),
                       "withheld(\(reason)) must not claim the transcript is on the clipboard")
                expect(!snapshot.statusText.contains("⌘V"),
                       "withheld(\(reason)) must not tell the user to press ⌘V")
                // P0 (UX writing): the text is in HISTORY, so never ask for a redo.
                expect(snapshot.statusText.contains("HISTORY"),
                       "withheld(\(reason)) points to HISTORY")
                expect(!snapshot.statusText.lowercased().contains("dictate again"),
                       "withheld(\(reason)) never asks to dictate again")
            }
            // Secure input keeps its explicit "kept private and not copied" wording.
            expectEqual(
                PasteOutcomePresenter.status(for: .withheld(.secureInputActive)),
                PasteStatusSnapshot(
                    phase: .notDelivered(headline: "NOT PASTED", reason: "SECURE INPUT · TEXT KEPT"),
                    statusText: "Secure input is on (a password field or a secure terminal). Your text is safe in HISTORY: press COPY."
                )
            )
        }

        test("pastePresenter.accessibilityPromptStatuses") {
            expectEqual(
                PasteOutcomePresenter.accessibilityRequestStatus(isTrusted: true),
                "Auto-paste is on."
            )
            expectEqual(
                PasteOutcomePresenter.accessibilityRequestStatus(isTrusted: false),
                "Waiting for macOS. If YappYapp is already on in Accessibility, remove it and add it again."
            )
            expectEqual(
                PasteOutcomePresenter.accessibilityRepairTimedOutStatus(),
                "Still not allowed. In System Settings > Privacy & Security > Accessibility, remove YappYapp, then add it again."
            )
        }
    }

    // MARK: - StatusFlavor

    private static func statusFlavorTests() {
        test("statusFlavor.poolsNonEmptyAndFactual") {
            expect(!StatusFlavor.transcribing.isEmpty, "transcribing pool is empty")
            expect(!StatusFlavor.nothingRecorded.isEmpty, "nothingRecorded pool is empty")
            expect(!StatusFlavor.idlePrompt.isEmpty, "idlePrompt pool is empty")
            // Privacy promise stays present and factual in the transcribing pool.
            expect(
                StatusFlavor.transcribing.contains("Still on this Mac. Always."),
                "transcribing pool dropped the factual privacy line"
            )
            // Canonical first lines preserved.
            expectEqual(StatusFlavor.transcribing[0], "Transcribing on this Mac…")
            expectEqual(StatusFlavor.nothingRecorded[0], "Heard nothing.")
            expectEqual(StatusFlavor.idlePrompt[0], "Press ⌥ space in any app and start talking.")
        }
        test("statusFlavor.indexWrapsSafely") {
            let pool = ["a", "b", "c"]
            expectEqual(StatusFlavor.line(from: pool, index: 0), "a")
            expectEqual(StatusFlavor.line(from: pool, index: 3), "a")
            expectEqual(StatusFlavor.line(from: pool, index: 4), "b")
            expectEqual(StatusFlavor.line(from: pool, index: -1), "c")
            expectEqual(StatusFlavor.line(from: [], index: 2), "")
        }
        test("statusFlavor.noEmDashes") {
            for line in StatusFlavor.transcribing + StatusFlavor.nothingRecorded + StatusFlavor.idlePrompt {
                expect(!line.contains("\u{2014}"), "em dash found in \(line)")
            }
        }
    }

    // MARK: - PetStats

    private static func petStatsTests() {
        // Deterministic anchor so the suite never straddles midnight: every date
        // below is derived from this one fixed instant, never the live wall
        // clock. Pinned through PetStatsStore.calendar (the same Gregorian/POSIX
        // calendar record() uses) so the day/week keys match production exactly.
        let base = PetStatsStore.calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 0
        ))!
        func day(_ offset: Int) -> Date {
            PetStatsStore.calendar.date(byAdding: .day, value: offset, to: base)!
        }

        func removeStatsPersistenceArtifacts(at primaryURL: URL) {
            let directory = primaryURL.deletingLastPathComponent()
            let prefix = primaryURL.lastPathComponent + "."
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for candidate in candidates
            where candidate == primaryURL || candidate.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: candidate)
            }
        }

        test("stats.sameDayAccumulates") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.record(words: 10, now: base)
            let stats = store.record(words: 5, now: base)
            expectEqual(stats.wordsToday, 15)
            expectEqual(stats.totalWords, 15)
            expectEqual(stats.streakDays, 1)
        }

        test("stats.consecutiveDaysGrowStreak") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.record(words: 10, now: day(-2))
            store.record(words: 10, now: day(-1))
            let stats = store.record(words: 10, now: day(0))
            expectEqual(stats.streakDays, 3)
            expectEqual(stats.wordsToday, 10)
            expectEqual(stats.totalWords, 30)
        }

        test("stats.gapResetsStreak") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.record(words: 10, now: day(-5))
            expectEqual(store.record(words: 10, now: day(0)).streakDays, 1)
        }

        // streak-empty-journeystart-fallback coverage: penguin must unlock at
        // exactly 3 genuine journey days and snail at exactly 5, and the
        // journey streak must track real elapsed time, not a one-day cap.
        test("stats.streakPetsUnlockOnGenuineJourneyDays") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.chooseStarter(.cat, now: day(-4))
            store.record(words: 10, pet: "cat", now: day(-4)) // journey day 1, streak 1
            store.record(words: 10, pet: "cat", now: day(-3)) // day 2, streak 2
            expect(!store.stats.isUnlocked(.penguin), "penguin still locked at 2 days")
            store.record(words: 10, pet: "cat", now: day(-2)) // day 3, streak 3
            expect(store.stats.isUnlocked(.penguin), "penguin unlocks at exactly 3 journey days")
            expect(!store.stats.isUnlocked(.snail), "snail still locked at 3 days")
            store.record(words: 10, pet: "cat", now: day(-1)) // day 4, streak 4
            store.record(words: 10, pet: "cat", now: day(0))  // day 5, streak 5
            expect(store.stats.isUnlocked(.snail), "snail unlocks at exactly 5 journey days")
            expectEqual(store.stats.journeyBestStreak, 5, "journey streak tracks genuine elapsed days")
        }

        // daysSinceJourneyStart returns nil for empty/unparseable input so the
        // record() fallback uses the raw streak instead of a bogus one-day cap.
        test("stats.daysSinceJourneyStartFallback") {
            expectEqual(PetStatsStore.daysSinceJourneyStart("", today: "2026-06-04"), nil,
                        "empty journeyStartDay yields nil (no usable start day)")
            expectEqual(PetStatsStore.daysSinceJourneyStart("not-a-date", today: "2026-06-04"), nil,
                        "unparseable journeyStartDay yields nil")
            expectEqual(PetStatsStore.daysSinceJourneyStart("2026-06-01", today: "2026-06-04"), 4,
                        "inclusive journey age counts the start day as day 1")
            expectEqual(PetStatsStore.daysSinceJourneyStart("2026-06-04", today: "2026-06-04"), 1,
                        "start day itself is journey day 1")
        }

        // The daily quest is picked from today's date; completing it doubles
        // pet XP. Word-counting tests neutralize that by completing whichever
        // quest today picked BEFORE making assertions, so the multiplier is
        // deterministically 2x regardless of the date.
        func completeTodaysQuest(_ store: PetStatsStore) {
            let early = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: base)!
            store.record(words: 400, pet: "none", now: early)
            for _ in 0..<4 {
                store.record(words: 1, pet: "none", now: early)
            }
            store.markGlossaryTaught(now: early)
        }

        test("stats.perPetWordsAndLevels") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            completeTodaysQuest(store)

            // petxp-gated-activepet: only unlocked pets bank XP, so the pets
            // this test attributes words to must first be unlocked. The cat is
            // chosen as the starter and the fox is unlocked through its own
            // journey-dictation quest (>= 25) using petless records that bank
            // no XP, leaving the per-pet word math below clean.
            store.chooseStarter(.cat, now: base)
            for _ in 0..<25 { store.record(words: 1, pet: "none", now: base) }
            expect(store.stats.isUnlocked(.cat), "cat unlocked as starter")
            expect(store.stats.isUnlocked(.fox), "fox unlocked at 25 journey dictations")

            store.record(words: 300, pet: "cat", now: base)
            store.record(words: 100, pet: "fox", now: base)
            store.record(words: 50, pet: "none", now: base)

            expectEqual(store.stats.words(for: .cat), 600, "300 words at quest 2x")
            expectEqual(store.stats.words(for: .fox), 200, "100 words at quest 2x")
            expectEqual(store.stats.words(for: .none), 0, "petless words are not attributed")
            expectEqual(petLevel(forWords: 300), 2)
            expectEqual(petLevel(forWords: 100), 1)

            let reloaded = PetStatsStore(url: url)
            expectEqual(reloaded.stats.words(for: .cat), 600)
        }

        test("stats.starterChoiceAndPokemonLadder") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            expect(!store.stats.isUnlocked(.cat), "everything locked before starter choice")
            expect(!store.stats.isUnlocked(.ghost), "ghost locked at zero words")

            store.chooseStarter(.dog, now: base)
            expect(store.stats.isUnlocked(.dog), "chosen starter unlocked")
            expect(store.stats.isEggPhase(.dog), "starter begins as an egg")
            expectEqual(store.stats.hatchProgress(.dog), 0, "starter hatch counter starts at zero")
            expect(!store.stats.isUnlocked(.cat), "other starters stay locked")
            expect(!store.stats.isUnlocked(.crab), "other starters stay locked")

            store.chooseStarter(.cat, now: base)
            expectEqual(store.stats.starter, "dog", "starter choice is one-time")

            store.record(words: 600, pet: "dog", now: base)
            expect(store.stats.isUnlocked(.ghost), "ghost unlocks at 500 words")
            expect(store.lastEvents.contains(.unlocked(.ghost)), "unlock event fires")
            expect(store.stats.isEggPhase(.ghost), "non-starter unlocks as an egg")
            expect(!store.stats.isUnlocked(.unicorn), "unicorn waits for level 10")

            store.record(words: 2_000, pet: "dog", now: base)
            expect(store.stats.isUnlocked(.cat), "remaining starters unlock at any pet level 6")
            expect(store.stats.maxPetLevel >= 6, "dog reached level 6")
        }

        test("stats.journeyStartsAtStarterChoice") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.record(words: 5_000, pet: "none", now: base)
            expect(!store.stats.isUnlocked(.ghost), "nothing unlocks before the starter choice")

            store.chooseStarter(.cat, now: base)
            expect(!store.stats.isUnlocked(.ghost), "pre-journey words do not unlock the ghost")
            expect(!store.stats.isUnlocked(.dragon), "pre-journey words do not unlock the dragon")
            expectEqual(store.stats.journeyWords, 0, "journey counter starts at zero")

            store.record(words: 500, pet: "cat", now: base)
            expect(store.stats.isUnlocked(.ghost), "journey words unlock the ghost")
            expect(!store.stats.isUnlocked(.dino), "dino still needs 2500 journey words")
        }

        test("stats.legacySaveMigratesToJourney") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            // A save from before journey tracking: starter chosen, big
            // lifetime counters, no journey baseline.
            let legacy = #"{"totalWords": 9000, "totalDictations": 300, "starter": "cat", "wordsByPet": {"cat": 4000}, "questsCompletedTotal": 8}"#
            try? legacy.data(using: .utf8)?.write(to: url)

            let store = PetStatsStore(url: url)
            expect(store.stats.isUnlocked(.cat), "starter survives migration")
            expect(!store.stats.isUnlocked(.ghost), "migration re-locks the ghost")
            expect(!store.stats.isUnlocked(.fox), "migration re-locks the fox")
            expect(!store.stats.isUnlocked(.otter), "migration re-locks quest pets")
            expectEqual(store.stats.words(for: .cat), 4_000, "per-pet XP survives migration (YA-68)")
            expect(store.stats.isEggPhase(.cat), "the starter goes back into its egg")
            expectEqual(store.stats.hatchProgress(.cat), 0)
            expectEqual(store.stats.journeyStartWords, 9_000)
            expectEqual(store.stats.totalWords, 9_000, "lifetime words are preserved")
        }

        test("stats.unicornNeedsLevelTen") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.chooseStarter(.cat, now: base)
            completeTodaysQuest(store)

            // 1,120 raw words at 2x = 2,240 pet XP = level 9.
            store.record(words: 1_120, pet: "cat", now: base)
            expect(!store.stats.isUnlocked(.unicorn), "level 9 is not enough")

            store.record(words: 30, pet: "cat", now: base)
            expect(store.stats.maxPetLevel >= 10, "cat reached level 10")
            expect(store.stats.isUnlocked(.unicorn), "unicorn unlocks at level 10")
        }

        test("stats.wardrobeIsPerPet") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.chooseStarter(.cat, now: base)
            store.record(words: 600, pet: "cat", now: base)

            store.setAccessory(.beanie, for: .cat)
            expectEqual(store.stats.accessory(for: .cat), .beanie, "cat earned and wears the beanie")
            expectEqual(store.stats.accessory(for: .dog), PetAccessory.none, "dog wardrobe untouched")

            store.setAccessory(.halo, for: .cat)
            expectEqual(store.stats.accessory(for: .cat), .beanie, "halo refused below level 10")

            store.setAccessory(.beanie, for: .dog)
            expectEqual(store.stats.accessory(for: .dog), PetAccessory.none, "level 1 dog cannot equip")
        }

        test("stats.eggHatchesAfter300Words") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.chooseStarter(.cat, now: base)
            store.record(words: 2_600, pet: "cat", now: base)
            expect(store.stats.isEggPhase(.dino), "unlocked pet starts as an egg")

            store.markEggStart(pet: "dino")
            expectEqual(store.stats.hatchProgress(.dino), 0)

            store.record(words: 200, pet: "dino", now: base)
            expect(store.stats.isEggPhase(.dino), "still an egg at 200/300")

            store.record(words: 150, pet: "dino", now: base)
            expect(!store.stats.isEggPhase(.dino), "hatched past 300 words")
            expect(store.lastEvents.contains(.hatched(.dino)), "hatch event fires")
        }

        test("stats.streakSaverCoversOneMissedDay") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            func day(_ offset: Int) -> Date {
                PetStatsStore.calendar.date(byAdding: .day, value: offset, to: base)!
            }

            let store = PetStatsStore(url: url)
            store.record(words: 10, pet: "cat", now: day(-3))
            store.record(words: 10, pet: "cat", now: day(-2))
            // Skip day -1 entirely; the saver should bridge it.
            store.record(words: 10, pet: "cat", now: day(0))

            expectEqual(store.stats.streakDays, 3, "saver bridged the gap")
            expect(store.lastEvents.contains(.streakSaved), "saver event fires")
        }

        test("stats.milestoneFiresOnceAtThreshold") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            store.record(words: 900, pet: "cat", now: base)
            expect(!store.lastEvents.contains(.milestone(1_000)), "below threshold")

            store.record(words: 150, pet: "cat", now: base)
            expect(store.lastEvents.contains(.milestone(1_000)), "milestone fires at crossing")

            store.record(words: 10, pet: "cat", now: base)
            expect(!store.lastEvents.contains(.milestone(1_000)), "milestone never repeats")
        }

        test("stats.questDeterministicAndDoublesXP") {
            expectEqual(DailyQuest.forDay("2026-06-10"), DailyQuest.forDay("2026-06-10"), "same day, same quest")

            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let store = PetStatsStore(url: url)
            // petxp-gated-activepet: the cat must be the unlocked active pet
            // before it can bank XP, so choose it as the starter first.
            store.chooseStarter(.cat, now: base)
            // Force completion regardless of which quest today's date picks.
            store.record(words: 400, pet: "cat", now: base)
            store.record(words: 400, pet: "cat", now: base)
            store.record(words: 400, pet: "cat", now: base)
            store.record(words: 400, pet: "cat", now: base)
            store.markGlossaryTaught(now: base)
            let early = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: base)!
            store.record(words: 400, pet: "cat", now: early)

            let today = PetStatsStore.dayString(base)
            expectEqual(store.stats.questCompletedDay, today, "today's quest completed")

            let before = store.stats.words(for: .cat)
            store.record(words: 100, pet: "cat", now: base)
            expectEqual(store.stats.words(for: .cat), before + 200, "completed quest doubles pet XP")
        }

        test("stats.legacyFileDecodesWithoutPerPet") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            let legacy = """
            {"totalWords": 9, "wordsToday": 9, "streakDays": 2, "lastDictationDay": "2026-06-09"}
            """
            try Data(legacy.utf8).write(to: url)

            let store = PetStatsStore(url: url)
            expectEqual(store.stats.totalWords, 9)
            expectEqual(store.stats.wordsByPet, [:])
        }

        test("stats.persistAcrossReload") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }

            PetStatsStore(url: url).record(words: 42, now: base)
            let reloaded = PetStatsStore(url: url)
            expectEqual(reloaded.stats.totalWords, 42)
            expectEqual(reloaded.stats.streakDays, 1)
        }

        test("stats.unversionedSchemaMigratesAndKeepsBackup") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            let legacy = Data(#"{"totalWords":73,"wordsByPet":{"cat":44}}"#.utf8)
            try legacy.write(to: url)

            let store = PetStatsStore(url: url)
            expectEqual(store.stats.totalWords, 73, "migration preserves lifetime progress")
            expectEqual(store.stats.wordsByPet["cat"], 44, "migration preserves per-pet progress")
            expectEqual(store.migratedFromSchemaVersion, 0)
            expectEqual(store.stats.schemaVersion, PetStats.currentSchemaVersion)
            expectEqual(store.recovery, nil, "valid legacy data is a migration, not corruption recovery")
            expect(store.persistenceIssues.isEmpty, "valid migration must not emit a failure")

            let primaryObject = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
            expectEqual(
                primaryObject?["schemaVersion"] as? Int,
                PetStats.currentSchemaVersion,
                "rewritten primary carries the explicit schema"
            )
            expectEqual(
                try Data(contentsOf: PetStatsStore.backupURL(for: url)),
                legacy,
                "migration preserves the exact last-known-good legacy bytes"
            )
        }

        test("stats.futureSchemaIsRejectedExplicitly") {
            let future = Data(#"{"schemaVersion":999,"totalWords":73}"#.utf8)
            do {
                _ = try PetStatsStore.decodeAndMigrate(future)
                expect(false, "future schema was accepted")
            } catch let error as PetStatsPersistenceError {
                expectEqual(error, .unsupportedSchemaVersion(999))
            } catch {
                expect(false, "unexpected future-schema error: \(error)")
            }
        }

        test("stats.backupKeepsPreviousKnownGoodSave") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            let backupURL = PetStatsStore.backupURL(for: url)
            let store = PetStatsStore(url: url)

            store.record(words: 10, now: base)
            expect(!FileManager.default.fileExists(atPath: backupURL.path),
                   "first save has no previous primary to back up")
            store.record(words: 5, now: base)

            let primary = try PetStatsStore.decodeAndMigrate(Data(contentsOf: url)).stats
            let backup = try PetStatsStore.decodeAndMigrate(Data(contentsOf: backupURL)).stats
            expectEqual(primary.totalWords, 15, "primary contains newest progress")
            expectEqual(backup.totalWords, 10, "backup contains previous known-good progress")
            expect(store.persistenceIssues.isEmpty, "normal backup rotation is clean")
        }

        test("stats.corruptPrimaryQuarantinesAndRecoversBackup") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            var unlocked = PetStats()
            unlocked.totalWords = 600
            unlocked.totalDictations = 25
            unlocked.starter = PetKind.cat.rawValue
            unlocked.wordsByPet[PetKind.cat.rawValue] = 600
            unlocked.journeyStartDay = PetStatsStore.dayString(day(-2))
            unlocked.eggStartWords[PetKind.cat.rawValue] = 0
            try PetStatsStore.encodedCurrentStats(unlocked).write(to: url)

            let store = PetStatsStore(url: url)
            store.record(words: 5, now: base)
            let corruptBytes = Data("{truncated".utf8)
            try corruptBytes.write(to: url, options: .atomic)

            let recovered = PetStatsStore(url: url)
            expectEqual(recovered.stats.totalWords, 600, "last-known-good backup is restored")
            expectEqual(recovered.stats.words(for: .cat), 600, "per-pet progress survives recovery")
            expect(recovered.stats.isUnlocked(.cat), "starter unlock survives recovery")
            expect(recovered.stats.isUnlocked(.ghost), "earned unlock survives recovery")
            expectEqual(recovered.lastLoadFailure?.operation, .loadPrimary)
            expectEqual(recovered.lastSaveFailure, nil, "successful recovery rewrite has no save failure")

            guard case let .restoredFromBackup(quarantinedFilename) = recovered.recovery else {
                expect(false, "backup recovery was not reported")
                return
            }
            expectEqual(quarantinedFilename, url.lastPathComponent + ".corrupt-1")
            let quarantineURL = URL(fileURLWithPath: url.path + ".corrupt-1")
            expectEqual(try Data(contentsOf: quarantineURL), corruptBytes,
                        "corrupt primary bytes are preserved for diagnosis")
            let healed = try PetStatsStore.decodeAndMigrate(Data(contentsOf: url)).stats
            expectEqual(healed.totalWords, 600, "primary is healed from the backup")
        }

        test("stats.corruptPrimaryWithoutBackupRestoresDefaults") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            let corruptBytes = Data("not-json".utf8)
            try corruptBytes.write(to: url)

            let recovered = PetStatsStore(url: url)
            expectEqual(recovered.stats, PetStats(), "defaults are used only when no backup exists")
            expectEqual(recovered.lastLoadFailure?.operation, .loadPrimary)
            guard case let .restoredDefaults(quarantinedFilename) = recovered.recovery else {
                expect(false, "default recovery was not reported")
                return
            }
            expectEqual(quarantinedFilename, url.lastPathComponent + ".corrupt-1")
            expectEqual(
                try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt-1")),
                corruptBytes,
                "unrecoverable primary is quarantined, not deleted"
            )
            _ = try PetStatsStore.decodeAndMigrate(Data(contentsOf: url))
            expect(true, "default recovery rewrites a valid primary")
        }

        test("stats.corruptPrimaryAndBackupQuarantinesBoth") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            let backupURL = PetStatsStore.backupURL(for: url)
            let corruptPrimary = Data("{bad-primary".utf8)
            let corruptBackup = Data("{bad-backup".utf8)
            try corruptPrimary.write(to: url)
            try corruptBackup.write(to: backupURL)

            let recovered = PetStatsStore(url: url)
            expectEqual(recovered.stats, PetStats())
            expectEqual(
                recovered.persistenceIssues.map(\.operation),
                [.loadPrimary, .loadBackup],
                "both failed reads remain observable"
            )
            expectEqual(recovered.recovery, .restoredDefaults(
                quarantinedFilename: url.lastPathComponent + ".corrupt-1"
            ))
            expectEqual(
                try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt-1")),
                corruptPrimary
            )
            expectEqual(
                try Data(contentsOf: URL(fileURLWithPath: backupURL.path + ".corrupt-1")),
                corruptBackup
            )
            _ = try PetStatsStore.decodeAndMigrate(Data(contentsOf: url))
            expect(true, "defaults are persisted after both copies fail")
        }

        test("stats.missingPrimaryRestoresValidBackup") {
            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            var backedUpStats = PetStats()
            backedUpStats.totalWords = 88
            try PetStatsStore.encodedCurrentStats(backedUpStats).write(
                to: PetStatsStore.backupURL(for: url)
            )

            let recovered = PetStatsStore(url: url)
            expectEqual(recovered.stats.totalWords, 88)
            expectEqual(recovered.lastLoadFailure, nil, "missing primary is not mislabeled as corruption")
            expectEqual(recovered.recovery, .restoredFromBackup(quarantinedFilename: nil))
            expect(FileManager.default.fileExists(atPath: url.path), "backup is restored to primary")
        }

        test("stats.saveFailureIsObservable") {
            let parentFile = temporaryURL("-blocked-parent")
            defer { try? FileManager.default.removeItem(at: parentFile) }
            try Data("not-a-directory".utf8).write(to: parentFile)
            let url = parentFile.appendingPathComponent("stats.json")
            let store = PetStatsStore(url: url)

            store.record(words: 3, now: base)
            expectEqual(store.stats.totalWords, 3, "in-memory progress remains available")
            expectEqual(store.lastSaveFailure?.operation, .save)
            expectEqual(store.lastSaveFailure?.filename, "stats.json")
            expect(!FileManager.default.fileExists(atPath: url.path), "failed save is not reported as durable")
        }

        // FIX questStaleRollover regression: yesterday's day-scoped counters must
        // never advance or auto-complete today's quest. Two layers: the pure
        // day-aware DailyQuest.progress gates on lastDictationDay, and the store's
        // rolloverIfNeeded() zeroes the counters the moment the calendar moves on.
        test("stats.questCannotCompleteFromStaleDayCounters") {
            var stale = PetStats()
            stale.lastDictationDay = PetStatsStore.dayString(day(-1))
            stale.wordsToday = 400
            stale.dictationsToday = 9
            let today = PetStatsStore.dayString(base)
            expectEqual(DailyQuest.threeHundredWords.progress(in: stale, day: today), 0,
                        "yesterday's 400 words do not advance today's 300-word quest")
            expectEqual(DailyQuest.fiveDictations.progress(in: stale, day: today), 0,
                        "yesterday's 9 dictations do not advance today's 5-dictation quest")
            // The same counters still count on the day they were written for.
            expectEqual(DailyQuest.threeHundredWords.progress(in: stale, day: stale.lastDictationDay), 300,
                        "same-day words count toward the quest")

            let url = temporaryURL(".json")
            defer { removeStatsPersistenceArtifacts(at: url) }
            let store = PetStatsStore(url: url)
            store.record(words: 400, pet: "none", now: day(-1))
            expectEqual(store.stats.wordsToday, 400, "yesterday's words recorded")
            store.rolloverIfNeeded(now: base)
            expectEqual(store.stats.wordsToday, 0, "day words zeroed once the calendar moved on")
            expectEqual(store.stats.dictationsToday, 0, "day dictations zeroed on rollover")
            // Rollover must not rewrite the streak day; record() owns streak state.
            expectEqual(store.stats.lastDictationDay, PetStatsStore.dayString(day(-1)),
                        "rollover leaves the streak day intact")
        }

        test("stats.debugUnlocksAreDerivedAndNonDestructive") {
            let persisted = PetStats()
            let presented = PetDebugAccess.presented(persisted, enabled: true)

            expect(persisted.starter.isEmpty, "debug access did not mutate the persisted value")
            expect(persisted.wordsByPet.isEmpty, "debug access did not inject persisted XP")
            for pet in PetKind.allCases {
                expect(presented.isUnlocked(pet), "\(pet.rawValue) is available in debug access")
                guard pet != .none else { continue }
                expect(!presented.isEggPhase(pet), "\(pet.rawValue) is hatched in debug access")
                expect(
                    petLevel(forWords: presented.words(for: pet)) >= PetAccessory.halo.unlockLevel,
                    "\(pet.rawValue) has the complete debug wardrobe"
                )
            }
        }
    }

    // MARK: - Time saved

    // MARKER privacyAndTimeSaved: tests
    private static func timeSavedTests() {
        test("timeSaved.minutesAreWordsOverWPM") {
            expectEqual(TimeSavedMath.minutesSaved(words: 40, typingWPM: 40), 1.0)
            expectEqual(TimeSavedMath.minutesSaved(words: 0), 0.0)
            expectEqual(TimeSavedMath.minutesSaved(words: -50), 0.0, "negative words clamp to zero")
            expectEqual(TimeSavedMath.minutesSaved(words: 100, typingWPM: 0), 100.0, "zero WPM cannot divide by zero")
        }
        test("timeSaved.shortLabelFormats") {
            expectEqual(TimeSavedMath.shortLabel(words: 0), "0m")
            expectEqual(TimeSavedMath.shortLabel(words: 40), "1m")
            expectEqual(TimeSavedMath.shortLabel(words: 2400), "1h")     // 2400/40 = 60
            expectEqual(TimeSavedMath.shortLabel(words: 5000), "2h 5m")  // 5000/40 = 125
        }
        test("timeSaved.noEmDashes") {
            for w in [0, 40, 2400, 5000] {
                expect(!TimeSavedMath.shortLabel(words: w).contains("\u{2014}"), "em dash in label")
            }
        }
    }

    // MARK: - PetEventPresenter

    private static func petEventPresenterTests() {
        test("petEvents.statusMessages") {
            expectEqual(
                PetEventPresenter.statusMessage(for: .milestone(1_000), activePet: "cat"),
                "Milestone: 1000 words dictated all time. Confetti earned."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .questCompleted, activePet: "cat"),
                "Daily quest complete. Your pet earns double XP today."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .levelUp(4), activePet: "cat"),
                "Cat reached level 4."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .levelUp(4), activePet: "mystery"),
                "Your pet reached level 4."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .unlocked(.ghost), activePet: "cat"),
                "New pet unlocked: Ghost. Find its egg in the Pet tab."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .hatched(.dino), activePet: "cat"),
                "The egg hatched. Say hi to your Dino."
            )
            expectEqual(
                PetEventPresenter.statusMessage(for: .streakSaved, activePet: "cat"),
                "You missed a day, but your pet covered for you. Streak saved."
            )
        }

        test("petEvents.preservesEventOrder") {
            expectEqual(
                PetEventPresenter.statusMessages(
                    for: [.questCompleted, .levelUp(2), .unlocked(.fox)],
                    activePet: "dog"
                ),
                [
                    "Daily quest complete. Your pet earns double XP today.",
                    "Dog reached level 2.",
                    "New pet unlocked: Fox. Find its egg in the Pet tab."
                ]
            )
        }
    }

    // MARK: - State

    private static func stateTests() {
        test("state.readinessPollingSleepsAfterSetup") {
            expectEqual(AppDelegate.readinessPollInterval(hasCompletedGuidedSetup: false), 2.0)
            expectEqual(AppDelegate.readinessPollInterval(hasCompletedGuidedSetup: true), 60.0)
        }

        test("state.historyNewestFirstAndCapped") {
            let state = YappYappState()
            for index in 1...15 {
                state.recordTranscript("message \(index)")
            }
            expectEqual(state.transcriptHistory.count, YappYappState.transcriptHistoryLimit)
            expectEqual(state.transcriptHistory.first?.text, "message 15")
            expectEqual(state.transcriptHistory.last?.text, "message 6")
        }

        test("state.levelHistoryFixedLength") {
            let state = YappYappState()
            for _ in 0..<100 {
                state.pushLevel(0.5)
            }
            expectEqual(state.levelHistory.count, YappYappState.levelSampleCount)
            state.resetLevels()
            expectEqual(state.levelHistory.count, YappYappState.levelSampleCount)
            expect(state.levelHistory.allSatisfy { $0 == 0 }, "levels cleared")
            expectEqual(state.recordingSeconds, 0)
        }
    }

    // MARK: - ModelCatalog

    private static func modelCatalogTests() {
        test("integrity.sha1") {
            let url = temporaryURL(".txt")
            defer { try? FileManager.default.removeItem(at: url) }

            try Data("abc".utf8).write(to: url)
            expectEqual(
                try ModelIntegrity.sha1Hex(for: url),
                "a9993e364706816aba3e25717850c26c9cd0d89d"
            )
        }

        test("integrity.rejectsChecksumMismatch") {
            let url = temporaryURL(".bin")
            defer { try? FileManager.default.removeItem(at: url) }

            try Data("abc".utf8).write(to: url)
            let option = ModelOption(
                id: "fixture",
                name: "Fixture",
                filename: "fixture.bin",
                badge: "Test",
                summary: "Checksum test fixture.",
                expectedSHA1: String(repeating: "0", count: 40)
            )

            do {
                try ModelIntegrity.verifyDownloadedFile(at: url, option: option)
                expect(false, "checksum mismatch should throw")
            } catch {
                expect(
                    error.localizedDescription.contains("Checksum mismatch for fixture.bin"),
                    "unexpected checksum error: \(error.localizedDescription)"
                )
            }
        }

        test("catalog.selectedID") {
            expectEqual(
                ModelCatalog.selectedID(for: "~/Library/Application Support/YappYapp/models/ggml-large-v3-turbo.bin"),
                "large-v3-turbo"
            )
            expectEqual(ModelCatalog.selectedID(for: "/anywhere/ggml-medium.en.bin"), "medium-en")
        }

        test("catalog.parakeetFirst") {
            expectEqual(ModelCatalog.options.first?.id, "parakeet-ultra")
            expectEqual(ModelCatalog.options.dropFirst().first?.id, "parakeet-v3", "v3 stays offered right after Ultra")
            let firstWhisper = ModelCatalog.options.firstIndex { $0.engine == .whisper }
            let lastParakeet = ModelCatalog.options.lastIndex { $0.engine == .parakeet }
            expect(firstWhisper != nil && lastParakeet != nil, "both engine families should exist")
            expect(lastParakeet! < firstWhisper!, "Parakeet models should render before Whisper models")
        }

        test("catalog.freshInstallDefaultsToParakeet") {
            let config = ConfigStore().defaultConfigForCurrentInstall()
            expectEqual(config.modelPath, "parakeet://ultra")
            expectEqual(ModelCatalog.selectedID(for: config.modelPath), "parakeet-ultra")
        }

        test("catalog.existingV3ConfigStaysOnV3") {
            // ULTRA: a saved v3 choice is never switched silently.
            let data = Data(#"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}"#.utf8)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            expectEqual(decoded.modelPath, "parakeet://v3")
            expectEqual(ModelCatalog.selectedID(for: decoded.modelPath), "parakeet-v3")
        }

        test("catalog.whisperDefaultsUseYappYappSupportPath") {
            // Under YAPPYAPP_APP_SUPPORT_BASE the defaults resolve to the
            // override's models folder instead of the tilde token.
            let expectedRoot = AppPaths.usesCustomApplicationSupportBase
                ? AppPaths.modelsDirectory.path
                : AppPaths.supportDirectoryToken
            for option in ModelCatalog.options where option.engine == .whisper {
                expect(
                    option.defaultPath.contains(expectedRoot),
                    "\(option.id) default path should use YappYapp support folder"
                )
            }
        }

        test("catalog.customFallback") {
            expectEqual(ModelCatalog.selectedID(for: "/tmp/some-model.gguf"), "custom")
            expectEqual(ModelCatalog.displayName(for: "/tmp/some-model.gguf"), "some-model.gguf")
        }

        test("catalog.uniqueIDs") {
            let ids = ModelCatalog.options.map(\.id)
            expectEqual(Set(ids).count, ids.count, "duplicate model ids")

            let whisperFilenames = ModelCatalog.options.filter { $0.engine == .whisper }.map(\.filename)
            expectEqual(Set(whisperFilenames).count, whisperFilenames.count, "duplicate whisper filenames")
        }

        test("catalog.whisperModelsCarryChecksums") {
            for option in ModelCatalog.options where option.engine == .whisper {
                expectEqual(option.expectedSHA1?.count, 40, "\(option.id) needs a SHA-1 checksum")
                expect(
                    option.expectedSHA1?.allSatisfy { $0.isHexDigit } == true,
                    "\(option.id) checksum must be hexadecimal"
                )
            }
        }

        test("catalog.parakeetFamily") {
            expectEqual(ModelCatalog.selectedID(for: "parakeet://ultra"), "parakeet-ultra")
            expectEqual(ModelCatalog.displayName(for: "parakeet://ultra"), "Parakeet Ultra")
            expect(DictationBadge.detectsLanguageItself("parakeet://ultra"), "Ultra picks the language itself, like v3")
            expectEqual(DictationBadge.modelLabel(for: "parakeet://ultra"), "PARAKEET ULTRA")
            expectEqual(ModelCatalog.selectedID(for: "parakeet://v3"), "parakeet-v3")
            expectEqual(ModelCatalog.selectedID(for: "parakeet://v2"), "parakeet-v2")
            expectEqual(ModelCatalog.selectedID(for: "parakeet://tdtCtc110m"), "parakeet-110m")
            expectEqual(ModelCatalog.selectedID(for: "parakeet://tdtJa"), "parakeet-ja")
            expectEqual(ModelCatalog.displayName(for: "parakeet://v3"), "Parakeet TDT v3")
            expect(ModelCatalog.engine(for: "parakeet://v2") == .parakeet, "parakeet engine detected")
            expect(ModelCatalog.engine(for: "/tmp/ggml-base.bin") == .whisper, "whisper engine default")

            for option in ModelCatalog.options where option.engine == .parakeet {
                expectEqual(option.defaultPath, "parakeet://\(option.parakeetVariant ?? "")")
            }
        }

        test("catalog.parakeetCacheDiagnostics") {
            expectEqual(ModelDiagnostics.parakeetCacheStatusOverride(from: [:]), nil)
            expectEqual(
                ModelDiagnostics.parakeetCacheStatusOverride(
                    from: [ModelDiagnostics.parakeetCacheStatusOverrideKey: "installed"]
                ),
                true
            )
            expectEqual(
                ModelDiagnostics.parakeetCacheStatusOverride(
                    from: [ModelDiagnostics.parakeetCacheStatusOverrideKey: " missing "]
                ),
                false
            )
            expectEqual(
                ModelDiagnostics.parakeetCacheStatusOverride(
                    from: [ModelDiagnostics.parakeetCacheStatusOverrideKey: "unknown"]
                ),
                nil
            )

            let cached = ModelDiagnostics.parakeetCacheSnapshot(
                for: "parakeet://v3",
                cachePath: { "/cache/\($0)" },
                isCached: { $0 == "v3" }
            )

            expectEqual(
                cached,
                ParakeetCacheSnapshot(
                    selectedModelID: "parakeet-v3",
                    selectedModelName: "Parakeet TDT v3",
                    variant: "v3",
                    cachePath: "/cache/v3",
                    isCached: true
                )
            )

            let missing = ModelDiagnostics.parakeetCacheSnapshot(
                for: "parakeet://tdtJa",
                cachePath: { "/cache/\($0)" },
                isCached: { _ in false }
            )
            expectEqual(missing?.variant, "tdtJa")
            expectEqual(missing?.cachePath, "/cache/tdtJa")
            expectEqual(missing?.isCached, false)

            let forcedMissing = ModelDiagnostics.parakeetCacheSnapshot(
                for: "parakeet://v3",
                forcedCacheStatus: false,
                cachePath: { "/cache/\($0)" },
                isCached: { _ in true }
            )
            expectEqual(forcedMissing?.isCached, false)

            expect(
                ModelDiagnostics.parakeetCacheSnapshot(for: "/tmp/ggml-base.bin") == nil,
                "Whisper models should not produce a Parakeet cache snapshot"
            )
        }
    }

    // MARK: - ModelReadinessPresenter

    private static func modelReadinessPresenterTests() {
        test("readiness.whisperUsesBinaryAndModelChecks") {
            var config = AppConfig.defaultConfig
            config.modelPath = "~/Library/Application Support/YappYapp/models/ggml-small.en.bin"

            expectEqual(
                ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: true, model: false)
                ),
                ModelReadinessSnapshot(
                    selectedModelID: "small-en",
                    selectedModelName: "Small English",
                    isWhisperReady: true,
                    isModelReady: false
                )
            )
        }

        test("readiness.parakeetIsManagedByFluidAudio") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            config.allowModelDownloads = true
            // YA-01: downloads allowed no longer counts as ready.

            expectEqual(
                ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: false),
                    selectedModelInstalled: false
                ),
                ModelReadinessSnapshot(
                    selectedModelID: "parakeet-v3",
                    selectedModelName: "Parakeet TDT v3",
                    isWhisperReady: true,
                    isModelReady: false
                )
            )
        }

        test("readiness.offlineParakeetRequiresPrecachedModel") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            config.allowModelDownloads = false

            expectEqual(
                ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: false),
                    selectedModelInstalled: false
                ),
                ModelReadinessSnapshot(
                    selectedModelID: "parakeet-v3",
                    selectedModelName: "Parakeet TDT v3",
                    isWhisperReady: true,
                    isModelReady: false
                )
            )

            expectEqual(
                ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: false),
                    selectedModelInstalled: true
                ),
                ModelReadinessSnapshot(
                    selectedModelID: "parakeet-v3",
                    selectedModelName: "Parakeet TDT v3",
                    isWhisperReady: true,
                    isModelReady: true
                )
            )
        }

        // Finding 4 regression: the readiness timer used to force isModelReady =
        // true for Parakeet unconditionally, defeating the honest offline check.
        // With downloads OFF and nothing cached, the presenter is the single
        // source of truth and must report the model NOT ready.
        test("readiness.parakeetNotReadyWithDownloadsOffAndEmptyCache") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            config.allowModelDownloads = false

            let snapshot = ModelReadinessPresenter.snapshot(
                config: config,
                whisperReadiness: (binary: false, model: false),
                selectedModelInstalled: false
            )
            expect(!snapshot.isModelReady,
                   "downloads off + empty cache must report the Parakeet model not ready")
            expect(snapshot.isWhisperReady,
                   "Parakeet does not depend on the whisper binary")
        }

        test("readiness.offlineParakeetMissingMessage") {
            expectEqual(
                ModelReadinessPresenter.parakeetOfflineMissingMessage(optionName: "Parakeet TDT v3"),
                "Parakeet TDT v3 isn't downloaded, and downloads are off. Turn them on in Setup, or ask your IT admin."
            )
        }

        test("readiness.customWhisperModelUsesFilenameDisplay") {
            var config = AppConfig.defaultConfig
            config.modelPath = "/tmp/custom-local-model.gguf"

            expectEqual(
                ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: true)
                ),
                ModelReadinessSnapshot(
                    selectedModelID: "custom",
                    selectedModelName: "custom-local-model.gguf",
                    isWhisperReady: false,
                    isModelReady: true
                )
            )
        }
    }

    // MARK: - ModelActivationPlanner

    private static func modelActivationPlannerTests() {
        test("activation.multilingualWhisperKeepsLanguage") {
            var config = AppConfig.defaultConfig
            config.language = "fr"
            let option = ModelCatalog.option(for: "large-v3-turbo")!

            let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)

            expectEqual(plan.config.modelPath, option.defaultPath)
            expectEqual(plan.config.language, "fr")
            expectEqual(plan.shouldPreloadParakeet, false)
            expectEqual(plan.statusText, "Using Large v3 Turbo. It runs on this Mac.")
        }

        test("activation.englishWhisperForcesEnglish") {
            var config = AppConfig.defaultConfig
            config.language = "auto"
            let option = ModelCatalog.option(for: "small-en")!

            let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)

            expectEqual(plan.config.modelPath, option.defaultPath)
            expectEqual(plan.config.language, "auto") // YA-25: saved language kept
            expectEqual(plan.shouldPreloadParakeet, false)
            expectEqual(plan.statusText, "Using Small English. It runs on this Mac.")
        }

        test("activation.englishParakeetForcesEnglishAndPreloads") {
            var config = AppConfig.defaultConfig
            config.language = "fr"

            for id in ["parakeet-v2", "parakeet-110m"] {
                let option = ModelCatalog.option(for: id)!
                let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)

                expectEqual(plan.config.modelPath, option.defaultPath)
                expectEqual(plan.config.language, "fr") // YA-25: saved language kept
                expectEqual(plan.shouldPreloadParakeet, true)
                expectEqual(plan.statusText, nil)
            }
        }

        test("activation.multilingualParakeetKeepsLanguageAndPreloads") {
            var config = AppConfig.defaultConfig
            config.language = "nl"
            let option = ModelCatalog.option(for: "parakeet-v3")!

            let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)

            expectEqual(plan.config.modelPath, "parakeet://v3")
            expectEqual(plan.config.language, "nl")
            expectEqual(plan.shouldPreloadParakeet, true)
            expectEqual(plan.statusText, nil)
        }
    }

    // MARK: - ModelDownloadPresenter

    private static func modelDownloadPresenterTests() {
        test("downloadPresenter.statusCopy") {
            expectEqual(
                ModelDownloadPresenter.downloadsOffStatus(lockedByAdmin: false),
                "Downloads are off. Turn them on in Setup."
            )
            // A managed Mac that locks the switch never sends the user to Setup.
            let locked = ModelDownloadPresenter.downloadsOffStatus(lockedByAdmin: true)
            expectEqual(locked, "Downloads are off on this Mac. Ask your IT admin.")
            expect(!locked.contains("Setup"), "locked copy offers no Setup route")
            expectEqual(ModelDownloadPresenter.canceledStatus, "Download canceled.")
            expectEqual(
                ModelDownloadPresenter.startedStatus(
                    optionName: "Large v3 Turbo",
                    selectedModelName: "Tiny English"
                ),
                "Downloading Large v3 Turbo\u{2026} Keep dictating with Tiny English meanwhile."
            )
            // One failure format for every engine.
            expectEqual(
                DownloadErrorCopy.status(optionName: "Parakeet TDT v3", plain: DownloadErrorCopy.offline),
                "Couldn't download Parakeet TDT v3. No internet connection. Connect and try again."
            )
        }

        test("downloadPresenter.notificationCopy") {
            expectEqual(
                ModelDownloadPresenter.managerFailedNotification(errorDescription: "timed out"),
                AppNotificationCopy(title: "Download failed", body: "timed out")
            )
            expectEqual(
                ModelDownloadPresenter.parakeetFailedNotification(
                    optionName: "Parakeet TDT v3",
                    errorDescription: "missing model manifest"
                ),
                AppNotificationCopy(title: "Download failed", body: "Parakeet TDT v3: missing model manifest")
            )
            expectEqual(
                ModelDownloadPresenter.readyNotification(optionName: "Small English"),
                AppNotificationCopy(
                    title: "Small English is ready.",
                    body: "Downloaded. Switching to it now."
                )
            )
        }
    }

    // MARK: - SetupReadinessPresenter

    private static func setupReadinessPresenterTests() {
        test("setupReadiness.noRowsWhenReady") {
            expectEqual(
                SetupReadinessPresenter.rows(
                    for: SetupReadinessInput(
                        isWhisperReady: true,
                        isModelReady: true,
                        isAccessibilityTrusted: true,
                        pasteWhenFocusIsUnclear: true,
                        allowModelDownloads: true,
                        activeDownloadProgress: nil
                    )
                ),
                []
            )
        }

        test("setupReadiness.guidesOnlineFirstRun") {
            let rows = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: false,
                    isModelReady: false,
                    isAccessibilityTrusted: false,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: true,
                    activeDownloadProgress: nil
                )
            )

            expectEqual(rows.map(\.id), ["whisper-runtime", "model-missing", "accessibility"])
            expectEqual(rows[0].action, nil)
            expectEqual(rows[1].actionTitle, "Download")
            expectEqual(rows[1].action, .downloadRecommendedModel)
            expectEqual(rows[2].actionTitle, "Allow")
            expectEqual(rows[2].action, .requestAccessibility)
            expectEqual(rows[2].title, "Allow auto-paste")
            expect(rows[2].detail.contains("older YappYapp"), "accessibility row outside the wizard explains the old entry")
            expect(!rows[2].detail.lowercased().contains("trust"), "never says trusted")
        }

        test("setupReadiness.guidesManagedOfflineInstall") {
            let rows = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: false,
                    isAccessibilityTrusted: true,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: false,
                    activeDownloadProgress: nil
                )
            )

            expectEqual(rows.count, 1)
            expectEqual(rows[0].id, "model-managed")
            expectEqual(rows[0].title, "No voice model yet")
            expect(rows[0].detail.contains("downloads are off"), "offline setup row explains disabled downloads")
            expect(rows[0].detail.contains("in Setup"), "the user's own switch is in Setup, never Settings")
            expectEqual(rows[0].actionTitle, "Setup")
            expectEqual(rows[0].action, .showSetup)

            // A managed Mac can't flip the switch: it asks the IT admin.
            let locked = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: false,
                    isAccessibilityTrusted: true,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: false,
                    activeDownloadProgress: nil,
                    downloadsLockedByOrganization: true
                )
            )
            expect(locked[0].detail.contains("ask your IT admin") || locked[0].detail.contains("Ask your IT admin"), "managed path")
            expect(!locked[0].detail.contains("Turn them on"), "no switch a locked user can't use")
            expectEqual(locked[0].action, .showModels)
        }

        test("setupReadiness.modelStepStatesSizeOnlyWhenKnown") {
            let v3 = SetupReadinessPresenter.modelDownloadDetail(name: "Parakeet TDT v3", id: "parakeet-v3")
            expect(v3.contains("480 MB") && v3.contains("one time"), "real size and one-time facts for the default")
            expect(!v3.contains("GB"), "Parakeet v3 is 483 MB, never about 1 GB")
            let ultra = SetupReadinessPresenter.modelDownloadDetail(name: "Parakeet Ultra", id: "parakeet-ultra")
            expect(ultra.contains("630 MB") && ultra.contains("one time"), "real size and one-time facts for Ultra")
            let other = SetupReadinessPresenter.modelDownloadDetail(name: "Large v3", id: "large-v3")
            expect(!other.contains("GB"), "no guessed size for other models")
            expect(other.contains("once"), "one-time fact")
        }

        test("setupReadiness.downloadProgressTitles") {
            let rows = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: false,
                    isAccessibilityTrusted: true,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: true,
                    activeDownloadProgress: 0.42
                )
            )
            expectEqual(rows[0].id, "model-download")
            expectEqual(rows[0].actionTitle, "42%")
            expectEqual(rows[0].action, .showModels)

            let spinnerRows = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: false,
                    isAccessibilityTrusted: true,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: true,
                    activeDownloadProgress: -1
                )
            )
            expectEqual(spinnerRows[0].actionTitle, "Models")
        }

        test("setupReadiness.noAccessibilityWarningWhenAutoPasteSettingIsOff") {
            let rows = SetupReadinessPresenter.rows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: true,
                    isAccessibilityTrusted: false,
                    pasteWhenFocusIsUnclear: false,
                    allowModelDownloads: true,
                    activeDownloadProgress: nil
                )
            )

            expect(!rows.contains { $0.id == "accessibility" }, "copy-only mode should not show an auto-paste permission warning")
        }

        // GUIDED-FIRST-RUN: the ordered wizard emits ONE numbered step at a time
        // in the fixed order Model -> Microphone -> Accessibility.
        func guided(
            model: Bool,
            mic: Bool,
            micDenied: Bool = false,
            accessibility: Bool,
            autoPaste: Bool = true
        ) -> [SetupReadinessRow] {
            SetupReadinessPresenter.guidedRows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: model,
                    isAccessibilityTrusted: accessibility,
                    pasteWhenFocusIsUnclear: autoPaste,
                    allowModelDownloads: true,
                    activeDownloadProgress: nil,
                    isMicrophoneAuthorized: mic,
                    isMicrophoneDenied: micDenied,
                    isGuidedFirstRun: true
                )
            )
        }

        test("guidedFirstRun.ordersModelMicAccessibility") {
            let step1 = guided(model: false, mic: false, accessibility: false)
            expectEqual(step1.count, 1, "first run shows exactly one step")
            expectEqual(step1[0].id, "model-missing")
            expectEqual(step1[0].stepBadge, "Step 1 of 3")
            expectEqual(step1[0].title, "Get the voice model")
            expectEqual(step1[0].stepMap, "Next: Allow the mic · Allow auto-paste", "every step is named up front")

            let step2 = guided(model: true, mic: false, accessibility: false)
            expectEqual(step2.count, 1)
            expectEqual(step2[0].id, "microphone")
            expectEqual(step2[0].stepBadge, "Step 2 of 3")
            expectEqual(step2[0].title, "Allow the mic")
            expectEqual(step2[0].stepMap, "Next: Allow auto-paste")
            expectEqual(step2[0].actionTitle, "Allow", "mirrors the macOS prompt")
            expectEqual(step2[0].action, .requestMicrophone)

            let step3 = guided(model: true, mic: true, accessibility: false)
            expectEqual(step3.count, 1)
            expectEqual(step3[0].id, "accessibility")
            expectEqual(step3[0].stepBadge, "Step 3 of 3")
            expectEqual(step3[0].title, "Allow auto-paste")
            expectEqual(step3[0].stepMap, nil, "the last step has nothing after it")

            let done = guided(model: true, mic: true, accessibility: true)
            expectEqual(done, [], "all required steps satisfied means no wizard rows")
        }

        test("guidedFirstRun.microphoneDeniedSwitchesToSettings") {
            let rows = guided(model: true, mic: false, micDenied: true, accessibility: false)
            expectEqual(rows.count, 1)
            expectEqual(rows[0].id, "microphone")
            expectEqual(rows[0].actionTitle, "Open")
            expectEqual(rows[0].action, .openMicrophoneSettings)
            expect(rows[0].detail.contains("System Settings > Privacy & Security > Microphone"), "denied copy points at System Settings")
        }

        test("guidedFirstRun.copyOnlyModeHasTwoSteps") {
            // Auto-paste off: accessibility is not a required step, so the count
            // is Model + Microphone only and the flag can flip without it.
            let step2 = guided(model: true, mic: false, accessibility: false, autoPaste: false)
            expectEqual(step2.count, 1)
            expectEqual(step2[0].id, "microphone")
            expectEqual(step2[0].stepBadge, "Step 2 of 2")

            let done = guided(model: true, mic: true, accessibility: false, autoPaste: false)
            expectEqual(done, [], "copy-only mode completes without accessibility")
        }

        test("guidedFirstRun.completedRunShowsAllOutstandingNotSingleStep") {
            let rows = SetupReadinessPresenter.guidedRows(
                for: SetupReadinessInput(
                    isWhisperReady: true,
                    isModelReady: false,
                    isAccessibilityTrusted: false,
                    pasteWhenFocusIsUnclear: true,
                    allowModelDownloads: true,
                    activeDownloadProgress: nil,
                    isMicrophoneAuthorized: false,
                    isMicrophoneDenied: false,
                    isGuidedFirstRun: false
                )
            )
            // YA-35: the auto-paste banner is the one prompt after the wizard.
            expectEqual(rows.map(\.id), ["model-missing", "microphone"], "completed run lists every outstanding issue")
            expect(rows.allSatisfy { $0.stepBadge == nil }, "no step badges after first run")
        }

        test("guidedFirstRun.noEmDashesInCopy") {
            let combos: [[SetupReadinessRow]] = [
                guided(model: false, mic: false, accessibility: false),
                guided(model: true, mic: false, accessibility: false),
                guided(model: true, mic: false, micDenied: true, accessibility: false),
                guided(model: true, mic: true, accessibility: false)
            ]
            for rows in combos {
                for row in rows {
                    expect(!row.title.contains("\u{2014}"), "em dash in guided title \(row.title)")
                    expect(!row.detail.contains("\u{2014}"), "em dash in guided detail \(row.detail)")
                    expect(!(row.stepBadge ?? "").contains("\u{2014}"), "em dash in step badge")
                }
            }
        }

        // pasteOffBanner: the banner shows iff Accessibility is not trusted,
        // independent of the pasteWhenFocusIsUnclear setting (unlike the setup
        // row). TCC itself is invisible to self-tests, so this guards the
        // trigger condition against the "silently skipped" failure mode.
        test("pasteOffBanner.showsWheneverUntrusted") {
            // Exercises the real production predicate both popovers now gate the
            // banner on (PasteOutcomePresenter.showsAutoPasteOffBanner), not a
            // restated local closure.
            expect(
                PasteOutcomePresenter.showsAutoPasteOffBanner(accessibilityTrusted: false),
                "banner must show when Accessibility is not trusted"
            )
            expect(
                !PasteOutcomePresenter.showsAutoPasteOffBanner(accessibilityTrusted: true),
                "banner must hide once Accessibility is trusted"
            )
        }
    }

    // MARK: - Stale accessibility (TCC) detector

    private static func staleAccessibilityDetectorTests() {
        func sig(_ wantsAutoPaste: Bool, _ isTrusted: Bool, _ wasTrusted: Bool, _ attempts: Int) -> StaleAccessibilitySignals {
            StaleAccessibilitySignals(
                wantsAutoPaste: wantsAutoPaste,
                isTrusted: isTrusted,
                wasTrustedThisSession: wasTrusted,
                grantAttempts: attempts
            )
        }

        test("staleTcc.cleanWhenTrusted") {
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(true, true, true, 5)), .clean)
        }
        test("staleTcc.firesRegardlessOfAutoPasteToggle") {
            // FIX staleTccGate: the detector no longer gates on the
            // pasteWhenFocusIsUnclear toggle. insertOrCopy blocks EVERY insertion
            // mode when AX is untrusted, so a stale/duplicate TCC entry hurts
            // users with the toggle off just as much and they must still be
            // offered the reset-and-regrant repair. Untrusted + previously
            // trusted this session => suspected, even with the toggle off.
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(false, false, true, 9)),
                        .suspected(.trustFlippedBack))
            // And the toggle being ON must not change that verdict either.
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(true, false, true, 9)),
                        .suspected(.trustFlippedBack))
        }
        test("staleTcc.firstRunNotYetGrantedIsClean") {
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(true, false, false, 1)), .clean)
        }
        test("staleTcc.trustFlippedBackIsSuspected") {
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(true, false, true, 0)), .suspected(.trustFlippedBack))
        }
        test("staleTcc.repeatedGrantsDidNotStick") {
            expectEqual(StaleAccessibilityDetector.verdict(for: sig(true, false, false, 2)), .suspected(.grantDidNotStick))
        }
        test("staleTcc.copyHasNoEmDashes") {
            let copy = [
                PasteOutcomePresenter.staleResetStatus(didReset: true),
                PasteOutcomePresenter.staleResetStatus(didReset: false),
                PasteOutcomePresenter.staleResetButtonTitle
            ]
            for line in copy {
                expect(!line.contains("\u{2014}"), "em dash found in \(line)")
            }
        }
    }

    // MARK: - ModelDownloadManager

    private static func modelDownloadTests() {
        test("download.fluidAudioNetworkPathAlwaysDisabled") {
            configureParakeetDownloads(allowed: true)
            expect(ModelHub.offlineMode, "FluidAudio networking enabled while verified downloads were allowed")
            configureParakeetDownloads(allowed: false)
            expect(ModelHub.offlineMode, "FluidAudio networking enabled in offline mode")
        }

        test("download.urlOnlyForWhisperModels") {
            let tiny = ModelCatalog.option(for: "tiny-en")!
            expectEqual(
                ModelDownloadManager.downloadURL(for: tiny)?.absoluteString,
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.en.bin"
            )

            let parakeet = ModelCatalog.option(for: "parakeet-v3")!
            expectEqual(ModelDownloadManager.downloadURL(for: parakeet), nil)
        }

        test("download.normalizedProgress") {
            expectEqual(
                ModelDownloadManager.normalizedProgress(totalBytesWritten: 50, totalBytesExpectedToWrite: 100),
                0.5
            )
            expectEqual(
                ModelDownloadManager.normalizedProgress(totalBytesWritten: 150, totalBytesExpectedToWrite: 100),
                1
            )
            expectEqual(
                ModelDownloadManager.normalizedProgress(totalBytesWritten: -10, totalBytesExpectedToWrite: 100),
                0
            )
            expectEqual(
                ModelDownloadManager.normalizedProgress(totalBytesWritten: 10, totalBytesExpectedToWrite: 0),
                nil
            )
            expectEqual(
                ModelDownloadManager.normalizedProgress(totalBytesWritten: 10, totalBytesExpectedToWrite: -1),
                nil
            )
        }

        test("download.httpStatusValidation") {
            expectEqual(ModelDownloadManager.httpStatusErrorMessage(nil), nil)
            expectEqual(ModelDownloadManager.httpStatusErrorMessage(200), nil)
            expectEqual(ModelDownloadManager.httpStatusErrorMessage(206), nil)
            expectEqual(ModelDownloadManager.httpStatusErrorMessage(302), "Download returned HTTP 302")
            expectEqual(ModelDownloadManager.httpStatusErrorMessage(404), "Download returned HTTP 404")
        }

        test("download.parakeetV3Plan") {
            let plan = ModelDownloadManager.parakeetDownloadPlan(for: "v3")
            expectEqual(plan.variant, "v3")
            expectEqual(plan.repo.folderName, "parakeet-tdt-0.6b-v3")
            expect(plan.requiredModelNames.contains("JointDecisionv3.mlmodelc"), "v3 should use the v3 joint graph")
            expect(plan.requiredModelNames.contains("Encoder.mlmodelc"), "v3 should use the int8 encoder by default")
            expect(plan.auxiliaryFileNames.contains("parakeet_vocab.json"), "v3 should include the vocabulary file")
            expectEqual(plan.revision, "aed02740059203c4a87495924f685de3722ae9ce")
            expect(!plan.revision.contains("main"), "Parakeet plan must pin an immutable commit")
        }

        test("download.parakeetUltraPlan") {
            let plan = ModelDownloadManager.parakeetDownloadPlan(for: "ultra")
            expectEqual(plan.variant, "ultra")
            expectEqual(plan.repo.remotePath, "FluidInference/parakeet-ultra-coreml")
            expectEqual(
                plan.requiredModelNames,
                ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"],
                "Ultra keeps the v3 file contract"
            )
            expect(plan.auxiliaryFileNames.contains("parakeet_vocab.json"), "Ultra should include the vocabulary file")
            expectEqual(plan.revision, "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
            expect(plan.repoDirectory != ModelDownloadManager.parakeetDownloadPlan(for: "v3").repoDirectory, "Ultra never shares v3's cache folder")
            expectEqual(asrVersion(forVariant: "ultra"), .ultra)
            let option = ModelCatalog.option(for: "parakeet-ultra")
            expectEqual(option?.defaultPath, "parakeet://ultra")
            expectEqual(option?.downloadBytes, 632_162_964)
        }

        test("download.manifestResolverSelectsPinnedFilesAndDigests") {
            let plan = ModelDownloadManager.parakeetDownloadPlan(for: "v3")
            let modelName = plan.requiredModelNames.sorted().first!
            let vocabularyName = plan.auxiliaryFileNames.sorted().first!
            let sha256 = String(repeating: "A", count: 64)
            let gitSHA1 = String(repeating: "b", count: 40)
            let items = [
                HuggingFaceTreeItem(
                    type: "file",
                    path: "\(modelName)/weights.bin",
                    size: 12,
                    oid: gitSHA1,
                    lfs: .init(oid: sha256, size: 12)
                ),
                HuggingFaceTreeItem(
                    type: "file",
                    path: vocabularyName,
                    size: 5,
                    oid: gitSHA1,
                    lfs: nil
                ),
                HuggingFaceTreeItem(
                    type: "file",
                    path: "unrelated/debug.txt",
                    size: 1,
                    oid: gitSHA1,
                    lfs: nil
                )
            ]
            var seenRemotePaths: Set<String> = []
            var seenLocalPaths: Set<String> = []
            let files = try ParakeetManifestResolver.resolve(
                items: items,
                plan: plan,
                seenRemotePaths: &seenRemotePaths,
                seenLocalPaths: &seenLocalPaths
            )

            expectEqual(files.count, 2)
            expectEqual(files[0].digestAlgorithm, .sha256)
            expectEqual(files[0].digest, sha256.lowercased())
            expectEqual(files[1].digestAlgorithm, .gitBlobSHA1)
            expectEqual(files[1].digest, gitSHA1)
            expect(!files.contains { $0.path == "unrelated/debug.txt" }, "unrequested file entered manifest")
        }

        test("download.manifestResolverRejectsDuplicateLocalPathsAcrossPages") {
            let base = ModelDownloadManager.parakeetDownloadPlan(for: "v3")
            let vocabularyName = base.auxiliaryFileNames.sorted().first!
            let plan = ParakeetDownloadPlan(
                variant: base.variant,
                version: base.version,
                repo: base.repo,
                revision: base.revision,
                requiredModelNames: base.requiredModelNames,
                auxiliaryFileNames: base.auxiliaryFileNames,
                targetDirectory: base.targetDirectory,
                repoDirectory: base.repoDirectory,
                subPath: "release"
            )
            let digest = String(repeating: "c", count: 40)
            var seenRemotePaths: Set<String> = []
            var seenLocalPaths: Set<String> = []

            _ = try ParakeetManifestResolver.resolve(
                items: [
                    HuggingFaceTreeItem(
                        type: "file",
                        path: "release/\(vocabularyName)",
                        size: 3,
                        oid: digest,
                        lfs: nil
                    )
                ],
                plan: plan,
                seenRemotePaths: &seenRemotePaths,
                seenLocalPaths: &seenLocalPaths
            )

            do {
                _ = try ParakeetManifestResolver.resolve(
                    items: [
                        HuggingFaceTreeItem(
                            type: "file",
                            path: vocabularyName,
                            size: 3,
                            oid: digest,
                            lfs: nil
                        )
                    ],
                    plan: plan,
                    seenRemotePaths: &seenRemotePaths,
                    seenLocalPaths: &seenLocalPaths
                )
                expect(false, "duplicate local manifest path accepted")
            } catch {
                expect(
                    error.localizedDescription.contains("multiple files"),
                    "unexpected duplicate-path error: \(error)"
                )
            }
        }

        test("download.cacheManifestRequiresPinnedRevisionAndUniquePaths") {
            let plan = ModelDownloadManager.parakeetDownloadPlan(for: "v3")
            let file = ParakeetRemoteFile(
                path: "Encoder.mlmodelc/weights.bin",
                localPath: "Encoder.mlmodelc/weights.bin",
                size: 5,
                digestAlgorithm: .sha256,
                digest: String(repeating: "d", count: 64)
            )
            let valid = ParakeetCacheManifest(
                schema: 1,
                repo: plan.repo.remotePath,
                revision: plan.revision,
                files: [file]
            )
            expect(ParakeetCacheRegistry.validates(manifest: valid, plan: plan), "valid pinned manifest rejected")

            let mutableRevision = ParakeetCacheManifest(
                schema: 1,
                repo: plan.repo.remotePath,
                revision: "main",
                files: [file]
            )
            expect(
                !ParakeetCacheRegistry.validates(manifest: mutableRevision, plan: plan),
                "mutable or mismatched revision accepted"
            )

            let duplicatePaths = ParakeetCacheManifest(
                schema: 1,
                repo: plan.repo.remotePath,
                revision: plan.revision,
                files: [file, file]
            )
            expect(
                !ParakeetCacheRegistry.validates(manifest: duplicatePaths, plan: plan),
                "duplicate cache paths accepted"
            )
        }

        test("download.parakeetPathsRejectTraversal") {
            expect(ModelDownloadManager.isSafeRelativeModelPath("Encoder.mlmodelc/coremldata.bin"), "valid nested path rejected")
            expect(!ModelDownloadManager.isSafeRelativeModelPath("../config.json"), "parent traversal accepted")
            expect(!ModelDownloadManager.isSafeRelativeModelPath("/tmp/model.bin"), "absolute path accepted")
            expect(!ModelDownloadManager.isSafeRelativeModelPath("Encoder.mlmodelc//model.bin"), "empty path component accepted")
            expect(!ModelDownloadManager.isSafeRelativeModelPath(#"Encoder.mlmodelc\model.bin"#), "backslash path accepted")
            expect(!ModelDownloadManager.isSafeRelativeModelPath("Encoder.mlmodelc/\0model.bin"), "NUL path accepted")
        }

        test("download.validatesRemoteDigests") {
            expect(ModelDownloadManager.isValidHexDigest(String(repeating: "a", count: 40), length: 40), "valid SHA-1 rejected")
            expect(ModelDownloadManager.isValidHexDigest(String(repeating: "A", count: 64), length: 64), "valid SHA-256 rejected")
            expect(!ModelDownloadManager.isValidHexDigest(String(repeating: "a", count: 39), length: 40), "short digest accepted")
            expect(!ModelDownloadManager.isValidHexDigest(String(repeating: "z", count: 40), length: 40), "non-hex digest accepted")
        }

        test("download.parsesHuggingFacePagination") {
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/example/tree/commit")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Link": "<https://huggingface.co/api/models/example/tree/commit?cursor=next>; rel=\"next\""
                ]
            )!
            expectEqual(
                ModelDownloadManager.nextPageURL(from: response)?.absoluteString,
                "https://huggingface.co/api/models/example/tree/commit?cursor=next"
            )

            let hostile = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/example/tree/commit")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Link": "<https://example.invalid/steal-token>; rel=next"]
            )!
            expectEqual(ModelDownloadManager.nextPageURL(from: hostile), nil, "cross-origin pagination accepted")
        }

        test("download.verifiesPinnedFileDigests") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yappyapp-integrity-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data("hello".utf8).write(to: url)

            let sha256 = ParakeetRemoteFile(
                path: "hello.bin",
                localPath: "hello.bin",
                size: 5,
                digestAlgorithm: .sha256,
                digest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
            let gitBlob = ParakeetRemoteFile(
                path: "hello.bin",
                localPath: "hello.bin",
                size: 5,
                digestAlgorithm: .gitBlobSHA1,
                digest: "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"
            )
            do {
                try ModelIntegrity.verifyParakeetFile(at: url, metadata: sha256)
                try ModelIntegrity.verifyParakeetFile(at: url, metadata: gitBlob)
                expect(true, "valid pinned digests accepted")
            } catch {
                expect(false, "valid pinned digest rejected: \(error)")
            }
        }

        test("download.registryTracksAndCleansTasks") {
            let option = ModelCatalog.option(for: "tiny-en")!
            let destination = URL(fileURLWithPath: "/tmp/ggml-tiny.en.bin")
            var registry = ModelDownloadRegistry()

            registry.track(taskID: 10, option: option, destination: destination)
            expectEqual(registry.count, 1)
            expectEqual(registry.taskID(for: option.id), 10)
            expectEqual(registry.record(for: 10), ModelDownloadRecord(option: option, destination: destination))

            let removed = registry.cleanup(taskID: 10, modelID: option.id)
            expectEqual(removed, ModelDownloadRecord(option: option, destination: destination))
            expect(registry.isEmpty, "registry should be empty after cleanup")
            expectEqual(registry.cleanup(taskID: 10, modelID: option.id), nil)
        }

        test("download.registryReplacesSameModelWithoutStaleCallbacks") {
            let option = ModelCatalog.option(for: "small")!
            var registry = ModelDownloadRegistry()

            registry.track(
                taskID: 1,
                option: option,
                destination: URL(fileURLWithPath: "/tmp/old.bin")
            )
            registry.track(
                taskID: 2,
                option: option,
                destination: URL(fileURLWithPath: "/tmp/new.bin")
            )

            expectEqual(registry.count, 1)
            expectEqual(registry.record(for: 1), nil)
            expectEqual(registry.taskID(for: option.id), 2)
            expectEqual(
                registry.cleanup(taskID: 1, modelID: option.id),
                nil,
                "stale task callback should not remove the replacement"
            )
            expectEqual(registry.taskID(for: option.id), 2)
            expectEqual(registry.cleanup(taskID: 2, modelID: option.id)?.destination.path, "/tmp/new.bin")
            expect(registry.isEmpty, "replacement cleanup should empty registry")
        }

        test("download.cancelHandoffAtomicallyResumesParkedRestart") {
            let option = ModelCatalog.option(for: "small")!
            let url = ModelDownloadManager.downloadURL(for: option)!
            var coordinator = WhisperDownloadCoordinator()

            let cancelGeneration = coordinator.prepareCancellation(
                modelID: option.id,
                hasActiveTask: true
            )
            let preparation = coordinator.prepareDownload(
                option: option,
                url: url,
                replacingActiveTask: false
            )
            expectEqual(preparation, .waitForCancellation)
            expectEqual(coordinator.pendingStartCount, 1)
            expect(coordinator.isCancellationInFlight(for: option.id), "cancel handoff not tracked")

            let resumeData = Data([1, 2, 3, 4])
            let pending = coordinator.completeCancellation(
                modelID: option.id,
                cancelGeneration: cancelGeneration,
                resumeData: resumeData
            )
            expectEqual(pending?.fallbackResumeData, resumeData)
            expectEqual(pending?.intent.option.id, option.id)
            expectEqual(coordinator.pendingStartCount, 0)
            expect(!coordinator.isCancellationInFlight(for: option.id), "cancel handoff never completed")
        }

        test("download.cancelInvalidatesParkedRestartAndStaleResumeBytes") {
            let option = ModelCatalog.option(for: "tiny-en")!
            let url = ModelDownloadManager.downloadURL(for: option)!
            var coordinator = WhisperDownloadCoordinator()

            let oldCancelGeneration = coordinator.prepareCancellation(
                modelID: option.id,
                hasActiveTask: true
            )
            _ = coordinator.prepareDownload(
                option: option,
                url: url,
                replacingActiveTask: false
            )
            let finalGeneration = coordinator.prepareCancellation(
                modelID: option.id,
                hasActiveTask: false
            )

            let pending = coordinator.completeCancellation(
                modelID: option.id,
                cancelGeneration: oldCancelGeneration,
                resumeData: Data([9, 9, 9])
            )
            expectEqual(pending, nil, "late cancel callback revived a canceled restart")
            expectEqual(coordinator.pendingStartCount, 0)
            expectEqual(coordinator.storedResumeData(for: option.id), nil, "stale resume bytes retained")
            expectEqual(coordinator.currentGeneration(for: option.id), finalGeneration)
        }

        test("download.newGenerationRejectsStaleResumeCallback") {
            let option = ModelCatalog.option(for: "small")!
            let url = ModelDownloadManager.downloadURL(for: option)!
            var coordinator = WhisperDownloadCoordinator()

            let first = coordinator.prepareDownload(
                option: option,
                url: url,
                replacingActiveTask: false
            )
            let firstGeneration: Int
            if case .start(let pending) = first {
                firstGeneration = pending.intent.generation
            } else {
                expect(false, "first download did not start")
                return
            }

            let second = coordinator.prepareDownload(
                option: option,
                url: url,
                replacingActiveTask: true
            )
            let secondGeneration: Int
            if case .reclaim(let pending) = second {
                secondGeneration = pending.intent.generation
            } else {
                expect(false, "replacement download did not reclaim active task")
                return
            }

            expect(
                !coordinator.storeResumeData(Data([1]), modelID: option.id, generation: firstGeneration),
                "stale generation stored resume bytes"
            )
            expect(
                coordinator.storeResumeData(Data([2]), modelID: option.id, generation: secondGeneration),
                "current generation rejected resume bytes"
            )
            expectEqual(coordinator.storedResumeData(for: option.id), Data([2]))
        }

        test("download.completionNotificationPolicy") {
            expect(!ModelDownloadManager.shouldNotifyCompletion(for: nil), "nil completion is success")
            expect(
                !ModelDownloadManager.shouldNotifyCompletion(for: URLError(.cancelled)),
                "user-initiated cancellation should not surface as a failure"
            )
            expect(
                ModelDownloadManager.shouldNotifyCompletion(for: URLError(.timedOut)),
                "network failures should notify the app"
            )
        }
    }

    // MARK: - WhisperServerController

    private static func warmServerTests() {
        test("server.binaryPathIsBesideWhisperCLI") {
            expectEqual(
                WhisperServerController.serverBinaryPath(
                    forWhisperBinaryPath: "/opt/homebrew/bin/whisper-cli"
                ),
                "/opt/homebrew/bin/whisper-server"
            )
        }

        test("server.promptCombinesGlossaryAndAdditionalPrompt") {
            var config = AppConfig.defaultConfig
            config.additionalPrompt = "  Product spellings: YappYapp and LUMEX.  "

            let glossary = Glossary(entries: [
                GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)
            ])
            let prompt = WhisperServerController.promptText(config: config, glossary: glossary)

            expect(prompt.contains("Genial"), "prompt missing glossary term: \(prompt)")
            expect(prompt.contains("YappYapp and LUMEX"), "prompt missing additional prompt: \(prompt)")
            expect(!prompt.contains("  Product"), "additional prompt should be trimmed: \(prompt)")
        }

        test("server.launchArgumentsMatchPackagedRuntimePolicy") {
            expectEqual(
                WhisperServerController.launchArguments(
                    model: "/models/ggml-large-v3-turbo.bin",
                    language: " fr ",
                    prompt: "Genial LUMEX",
                    translate: true,
                    quietBoost: true
                ),
                [
                    "-m", "/models/ggml-large-v3-turbo.bin",
                    "--host", "127.0.0.1",
                    "--port", "18027",
                    "-nt",
                    "-sns",
                    "-l", "fr",
                    "-tr",
                    "-nth", "0.95",
                    "-bs", "5"
                ]
            )
            let arguments = WhisperServerController.launchArguments(
                model: "/models/ggml-large-v3-turbo.bin",
                language: "fr",
                prompt: "PrivateClientName",
                translate: false,
                quietBoost: false
            )
            expect(!arguments.contains("PrivateClientName"), "glossary prompt must not enter server argv")

            expectEqual(
                WhisperServerController.launchArguments(
                    model: "/models/ggml-base.bin",
                    language: "   ",
                    prompt: "",
                    translate: false,
                    quietBoost: false
                ),
                [
                    "-m", "/models/ggml-base.bin",
                    "--host", "127.0.0.1",
                    "--port", "18027",
                    "-nt",
                    "-sns"
                ]
            )
        }

        test("server.launchSignatureChangesOnRuntimeInputs") {
            let base = WhisperServerController.launchSignature(
                binary: "/bin/whisper-server",
                model: "/models/a.bin",
                language: "en",
                prompt: "Genial",
                translate: false,
                quietBoost: true
            )

            expectEqual(base, "/bin/whisper-server|/models/a.bin|en||boost")
            expect(
                base != WhisperServerController.launchSignature(
                    binary: "/bin/whisper-server",
                    model: "/models/a.bin",
                    language: "fr",
                    prompt: "Genial",
                    translate: false,
                    quietBoost: true
                ),
                "language changes must restart the warm server"
            )
            expect(
                base == WhisperServerController.launchSignature(
                    binary: "/bin/whisper-server",
                    model: "/models/a.bin",
                    language: "en",
                    prompt: "Genial extra",
                    translate: false,
                    quietBoost: true
                ),
                "prompt changes must not restart a server that reads prompts per request"
            )
            expect(
                base != WhisperServerController.launchSignature(
                    binary: "/bin/whisper-server",
                    model: "/models/a.bin",
                    language: "en",
                    prompt: "Genial",
                    translate: true,
                    quietBoost: true
                ),
                "translation changes must restart the warm server"
            )
        }

        test("server.promptTravelsInLocalRequestBody") {
            let body = WhisperServerController.inferenceMultipartBody(
                boundary: "audit-boundary",
                prompt: "PrivateClientName",
                audioData: Data("WAVE".utf8)
            )
            let text = String(decoding: body, as: UTF8.self)
            expect(text.contains("name=\"prompt\""), "multipart body must include prompt field")
            expect(text.contains("PrivateClientName"), "current glossary prompt must reach inference")
            expect(text.contains("WAVE"), "multipart body must include audio bytes")
        }

        test("server.normalizesInferenceResponse") {
            let data = Data(#"{"text":"  hello\r\nworld\n "}"#.utf8)
            expectEqual(try WhisperServerController.normalizedInferenceText(from: data), "hello\nworld")
        }

        test("server.rejectsEmptyInferenceResponse") {
            do {
                _ = try WhisperServerController.normalizedInferenceText(from: Data(#"{"text":" \n "}"#.utf8))
                expect(false, "empty server response should throw")
            } catch {
                expect(
                    error.localizedDescription == WhisperError.emptyTranscript.localizedDescription,
                    "unexpected empty transcript error: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Pixel pets

    private static func spriteTests() {
        let sprites: [(name: String, sprite: PetSprite)] = [
            ("cat", catSprite),
            ("dog", dogSprite),
            ("ghost", ghostSprite),
            ("penguin", penguinSprite),
            ("fox", foxSprite),
            ("frog", frogSprite),
            ("crab", crabSprite),
            ("robot", robotSprite),
            ("dino", dinoSprite),
            ("duck", duckSprite),
            ("snail", snailSprite),
            ("otter", otterSprite),
            ("dragon", dragonSprite),
            ("unicorn", unicornSprite),
            ("clawd", clawdSprite),
            ("egg", eggSprite)
        ]

        test("sprites.rectangular") {
            for (name, sprite) in sprites {
                for frame in PetFrame.allCases {
                    let grid = sprite.grid(for: frame)
                    expect(!grid.isEmpty, "\(name)/\(frame) is empty")
                    expectEqual(Set(grid.map(\.count)).count, 1, "\(name)/\(frame) ragged rows")
                }
            }
        }

        test("sprites.feetTouchTheGround") {
            for (name, sprite) in sprites {
                for frame in PetFrame.allCases {
                    let lastRow = sprite.grid(for: frame).last ?? []
                    expect(
                        lastRow.contains { $0 != "." },
                        "\(name)/\(frame) has an empty bottom row: the pet floats above the bar"
                    )
                }
            }
        }

        test("sprites.paletteCoversEveryPixel") {
            for (name, sprite) in sprites {
                for frame in PetFrame.allCases {
                    for row in sprite.grid(for: frame) {
                        for character in row where character != "." {
                            expect(
                                sprite.palette[character] != nil,
                                "\(name)/\(frame): '\(character)' missing from palette (renders as a hole)"
                            )
                        }
                    }
                }
            }
        }

        test("sprites.walkFramesShareWidth") {
            for (name, sprite) in sprites {
                expectEqual(
                    sprite.walkA.first?.count, sprite.walkB.first?.count,
                    "\(name) stride jitters"
                )
            }
        }

        test("sprites.parseTrimsTrailingEmptyRows") {
            let grid = parse("""
            .#.
            ###
            ...
            ...
            """)
            expectEqual(grid.count, 2)
            expectEqual(grid.last, ["#", "#", "#"])
        }

        test("sprites.parsePadsRaggedRows") {
            let grid = parse("""
            ##
            #
            """)
            expectEqual(grid[0].count, grid[1].count)
            expectEqual(grid[1], ["#", "."])
        }
    }

    // MARK: - Entry point

    // MARK: - UX state machine

    private static func uxStateTests() {
        test("ux.phaseLabelsAndSymbols") {
            let phases: [CapturePhase] = [.idle, .recording, .transcribing, .copied, .pasted, .error("boom")]
            for phase in phases {
                expect(!phase.label.isEmpty, "phase \(phase) has a label")
                expect(!phase.symbolName.isEmpty, "phase \(phase) has a symbol")
            }
            expectEqual(CapturePhase.recording.label, "Listening")
            expectEqual(CapturePhase.error("x").label, "Needs attention")
            expectEqual(CapturePhase.pasted.label, "Pasted")
        }

        test("ux.transcriptHistoryCapsAtTen") {
            let state = YappYappState()
            for index in 1...12 {
                state.recordTranscript("entry \(index)")
            }
            expectEqual(state.transcriptHistory.count, YappYappState.transcriptHistoryLimit)
            expectEqual(state.transcriptHistory.first?.text, "entry 12", "newest entry first")
            expectEqual(state.transcriptHistory.last?.text, "entry 3", "oldest beyond the cap dropped")
        }

        test("ux.levelHistorySlidingWindow") {
            let state = YappYappState()
            expectEqual(state.levelHistory.count, YappYappState.levelSampleCount)

            state.pushLevel(0.8)
            expectEqual(state.levelHistory.count, YappYappState.levelSampleCount, "window size is constant")
            expectEqual(state.levelHistory.last, 0.8, "newest sample lands at the end")

            state.recordingSeconds = 7
            state.resetLevels()
            expect(state.levelHistory.allSatisfy { $0 == 0 }, "reset clears the waveform")
            expectEqual(state.recordingSeconds, 0)
        }

        test("ux.activePetRequiresUnlock") {
            let state = YappYappState()
            var stats = PetStats()

            state.config.pet = "dragon"
            state.petStats = stats
            expectEqual(state.activePet, PetKind.none, "locked pet never walks the bar")

            stats.starter = "cat"
            stats.journeyStartDay = "2026-01-01"
            state.petStats = stats
            state.config.pet = "cat"
            expectEqual(state.activePet, PetKind.cat, "unlocked starter is active")

            state.config.pet = "not-a-pet"
            expectEqual(state.activePet, PetKind.none, "unknown raw value falls back to none")
        }

        test("ux.modelCatalogRoundTrip") {
            for option in ModelCatalog.options {
                expectEqual(ModelCatalog.selectedID(for: option.defaultPath), option.id, "path of \(option.id) routes back")
                expectEqual(ModelCatalog.engine(for: option.defaultPath), option.engine, "engine of \(option.id)")
                expect(!option.name.isEmpty && !option.summary.isEmpty && !option.badge.isEmpty, "\(option.id) copy complete")
            }
            expectEqual(ModelCatalog.selectedID(for: "~/somewhere/ggml-imaginary.bin"), "custom")
            expectEqual(ModelCatalog.engine(for: "parakeet://v3"), ModelEngine.parakeet)
            expectEqual(ModelCatalog.displayName(for: "parakeet://v2"), "Parakeet TDT v2")
        }

        test("ux.transcriptExpansionIsBounded") {
            expectEqual(TranscriptHistoryLayout.latestCompactLineLimit, 6)
            expectEqual(TranscriptHistoryLayout.olderCompactLineLimit, 2)
            expect(TranscriptHistoryLayout.expandedTextMaxHeight >= 100, "expanded transcript should allow useful reading room")
            expect(TranscriptHistoryLayout.expandedTextMaxHeight <= 160, "expanded transcript must stay bounded inside the popover")
        }

        test("ux.featureTipsCoverDiscovery") {
            expectEqual(FeatureTips.items.count, 5)
            let allText = FeatureTips.items.map { "\($0.title) \($0.body)" }.joined(separator: " ").lowercased()
            for needle in ["cleanup", "words", "instant start", "option space", "pet"] {
                expect(allText.contains(needle), "tips should mention \(needle)")
            }
            // UX-WRITING: the canonical terms only, no jargon.
            for banned in ["llm", "qwen", "hotkey", "glossary", "vocabulary", "super fast"] {
                expect(!allText.contains(banned), "tips must not say \(banned)")
            }
            for tip in FeatureTips.items {
                expect(!tip.title.contains("\u{2014}") && !tip.body.contains("\u{2014}"), "tips must not use em dashes")
            }
            expectEqual(FeatureTips.nextIndex(after: FeatureTips.items.count - 1), 0)
        }

        test("pet.emotesAreShortAndStepped") {
            expectEqual(Set(PetEmote.allCases), Set([.hop, .spin, .heart, .zzz, .wiggle]))
            for emote in PetEmote.allCases {
                expect(emote.duration >= 1.0 && emote.duration <= 2.0, "\(emote) should stay short")
            }

            let start = Date(timeIntervalSinceReferenceDate: 0)
            let later = start.addingTimeInterval(PetEmote.stepInterval * 3.2)
            expectEqual(PetEmote.hop.step(startedAt: start, now: later), 3)
            expect(PetEmote.hop.lift(step: 2, pixel: 2) > PetEmote.hop.lift(step: 0, pixel: 2), "hop should move upward in steps")
            expect(PetEmote.wiggle.horizontalOffset(step: 1, pixel: 2) != PetEmote.wiggle.horizontalOffset(step: 2, pixel: 2), "wiggle should snap side to side")
            expect(PetEmote.spin.mirrored(base: false, step: 2), "spin should flip the sprite on stepped frames")
            expect(PetEmote.zzz.usesSleepFrame, "zzz emote should use the sleep frame")
        }

        test("ux.daysBetween") {
            expectEqual(PetStatsStore.daysBetween("2026-06-01", and: "2026-06-01"), 0)
            expectEqual(PetStatsStore.daysBetween("2026-06-01", and: "2026-06-04"), 3)
            expectEqual(PetStatsStore.daysBetween("2026-06-04", and: "2026-06-01"), 0, "reversed clamps to zero")
            expectEqual(PetStatsStore.daysBetween("", and: "2026-06-01"), 0, "missing start is safe")
            expectEqual(PetStatsStore.daysBetween("garbage", and: "2026-06-01"), 0, "unparseable is safe")
        }

        test("ux.dailyQuestCopyComplete") {
            for quest in DailyQuest.allCases {
                expect(!quest.title.isEmpty, "\(quest.rawValue) has a title")
                expect(quest.target > 0, "\(quest.rawValue) has a positive target")
            }
        }
    }

    // MARK: - UI accessibility contracts

    private static func uiAccessibilityContractTests() {
        test("ui.keyboardDisclosureAcceptsReturnAndSpace") {
            expectEqual(BrutalKeyboardActivation.keys, [.return, .space])

            var activations = 0
            let result = BrutalKeyboardActivation.perform {
                activations += 1
            }
            expectEqual(activations, 1, "keyboard activation should invoke its action exactly once")
            if case .handled = result {
                passed += 1
            } else {
                failures.append("[\(currentTest)] keyboard activation should report handled")
            }
        }

        test("ui.transcriptDisclosureSemanticsStayContextual") {
            let transcript = "A deterministic transcript"
            expectEqual(BrutalTranscriptDisclosure.collapsed.label, "Show all")
            expectEqual(
                BrutalTranscriptDisclosure.collapsed.hint,
                "Shows the whole dictation"
            )
            expectEqual(
                BrutalTranscriptDisclosure.collapsed.value(for: transcript),
                "Collapsed. \(transcript)"
            )
            expectEqual(BrutalTranscriptDisclosure.expanded.label, "Show less")
            expectEqual(
                BrutalTranscriptDisclosure.expanded.hint,
                "Shows only the first lines again"
            )
            expectEqual(
                BrutalTranscriptDisclosure.expanded.value(for: transcript),
                "Expanded. \(transcript)"
            )
        }

        test("ui.petPreviewReduceMotionUsesStaticFrame") {
            let first = Date(timeIntervalSinceReferenceDate: 0)
            let second = first.addingTimeInterval(PetPreviewAnimationPolicy.interval)
            expectEqual(PetPreviewAnimationPolicy.frame(at: first, reduceMotion: true), .walkA)
            expectEqual(PetPreviewAnimationPolicy.frame(at: second, reduceMotion: true), .walkA)
            expectEqual(PetPreviewAnimationPolicy.frame(at: first, reduceMotion: false), .walkA)
            expectEqual(PetPreviewAnimationPolicy.frame(at: second, reduceMotion: false), .walkB)
        }
    }

    // MARK: - UI rendering

    @MainActor
    static func renderImage<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSImage? {
        // ImageRenderer draws ScrollView content blank, so tab bodies render
        // as plain top-aligned stacks here (YA-41).
        let renderer = ImageRenderer(
            content: view
                .environment(\.brutalFlattensScroll, true)
                .frame(width: width, height: height)
        )
        renderer.scale = 1
        return renderer.nsImage
    }

    struct PixelSnapshot {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        var opaquePixelCount: Int {
            stride(from: 3, to: rgba.count, by: 4).reduce(into: 0) { count, index in
                if rgba[index] > 0 { count += 1 }
            }
        }

        var fingerprint: UInt64 {
            rgba.reduce(into: UInt64(1_469_598_103_934_665_603)) { hash, byte in
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        func pixel(x: Int, y: Int) -> [UInt8] {
            guard x >= 0, x < width, y >= 0, y < height else { return [] }
            let offset = (y * width + x) * 4
            return Array(rgba[offset..<(offset + 4)])
        }
    }

    @MainActor
    static func renderPixelSnapshot<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat
    ) -> PixelSnapshot? {
        guard let image = renderImage(view, width: width, height: height) else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let pixelWidth = source.width
        let pixelHeight = source.height
        var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: &rgba,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.setBlendMode(.copy)
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return PixelSnapshot(width: pixelWidth, height: pixelHeight, rgba: rgba)
    }

    @MainActor
    private static func expectRenders<V: View>(
        _ name: String,
        _ view: V,
        width: CGFloat = 440,
        height: CGFloat = 600,
        line: Int = #line
    ) {
        guard let image = renderImage(view, width: width, height: height) else {
            failures.append("[\(currentTest):\(line)] \(name) failed to render")
            return
        }
        if image.size.width > 0 && image.size.height > 0 {
            passed += 1
        } else {
            failures.append("[\(currentTest):\(line)] \(name) rendered with zero size")
        }
    }

    static func makeUIState(
        phase: CapturePhase = .idle,
        downloads: [String: Double] = [:],
        starter: PetKind? = .cat,
        hatched: Bool = true,
        allowModelDownloads: Bool = true
    ) -> YappYappState {
        let state = YappYappState()
        state.phase = phase
        state.statusText = "Status line for rendering"
        state.lastTranscript = "The quick brown fox jumps over the lazy dog."
        state.isWhisperReady = true
        state.isModelReady = true
        state.isAccessibilityTrusted = true
        state.modelDownloads = downloads
        state.config.allowModelDownloads = allowModelDownloads
        state.glossaryEntries = Glossary.defaultEntries
        state.recordTranscript("A previous dictation for the history list.")

        if phase == .recording {
            for index in 0..<YappYappState.levelSampleCount {
                state.pushLevel(Double(index % 10) / 10.0)
            }
        }

        var stats = PetStats()
        if let starter {
            stats.starter = starter.rawValue
            stats.journeyStartDay = "2026-01-01"
            stats.totalWords = 5_000
            stats.totalDictations = 120
            stats.streakDays = 4
            stats.bestStreak = 6
            stats.journeyBestStreak = 4
            stats.wordsByPet = [starter.rawValue: hatched ? 1_400 : 0]
            stats.eggStartWords = [starter.rawValue: hatched ? 0 : 4_900]
            stats.weekWords = 900
            state.config.pet = starter.rawValue
        }
        state.petStats = stats
        return state
    }

    static func makeBrutalPopover(_ state: YappYappState) -> BrutalistPopoverView {
        BrutalistPopoverView(
            state: state,
            onToggleRecording: {}, onSelectModel: { _ in }, onDownloadModel: { _ in },
            onCancelDownload: { _ in }, onSaveConfig: { _ in }, onSaveGlossary: { _ in },
            onRequestAccessibility: {}, onResetAndRegrantAccessibility: {},
            onRequestMicrophone: {}, onOpenMicrophoneSettings: {},
            onSetLaunchAtLogin: { _ in }, onChooseStarter: { _ in },
            onEquipAccessory: { _ in }, onSaveRecap: {}, onCopyText: { _ in },
            onRevealSupport: {}, onQuit: {}
        )
    }

    /// Offscreen ImageRenderer smoke pass over every screen, tab, and state
    /// in the Brutalist skin: a render that returns nil or zero pixels means a view
    /// crashed or collapsed, the UI equivalent of a failed unit test.
    private static func uiRenderTests() {
        MainActor.assumeIsolated {
            test("ui.brutalistPopoverTabsRender") {
                let state = makeUIState()
                let brutal = makeBrutalPopover(state)

                expectRenders("brutal.body", brutal)
                expectRenders("brutal.home", brutal.homeTab)
                expectRenders("brutal.files", brutal.filesTab)
                expectRenders("brutal.models", brutal.modelsTab)
                expectRenders("brutal.words", brutal.wordsTab)
                expectRenders("brutal.pet", brutal.petTab)
                expectRenders("brutal.settings", brutal.settingsTab)
            }

            test("ui.pixelCanvasMirroringMatchesDeterministicSnapshot") {
                let grid = parse("""
                #y
                y#
                """)
                let palette: [Character: Color] = ["#": Brutal.ink, "y": Brutal.yellow]
                guard let normal = renderPixelSnapshot(
                    PixelSpriteCanvas(grid: grid, palette: palette, pixel: 3, mirrored: false),
                    width: 6,
                    height: 6
                ), let mirrored = renderPixelSnapshot(
                    PixelSpriteCanvas(grid: grid, palette: palette, pixel: 3, mirrored: true),
                    width: 6,
                    height: 6
                ) else {
                    failures.append("[\(currentTest)] pixel canvas snapshot failed to render")
                    return
                }

                expectEqual(normal.width, 6)
                expectEqual(normal.height, 6)
                expectEqual(normal.opaquePixelCount, 36)
                expectEqual(mirrored.opaquePixelCount, 36)
                expect(normal.fingerprint != mirrored.fingerprint, "mirroring should change the pixel fingerprint")
                expectEqual(normal.pixel(x: 0, y: 0), mirrored.pixel(x: 5, y: 0))
                expectEqual(normal.pixel(x: 5, y: 0), mirrored.pixel(x: 0, y: 0))
            }

            test("ui.settingsSnapshotIsStableAtMaximumDynamicType") {
                let firstState = makeUIState()
                let secondState = makeUIState()
                let firstView = makeBrutalPopover(firstState).settingsTab.background(Brutal.paper)
                let secondView = makeBrutalPopover(secondState).settingsTab.background(Brutal.paper)
                guard let first = renderPixelSnapshot(firstView, width: 440, height: 596),
                      let repeated = renderPixelSnapshot(secondView, width: 440, height: 596),
                      let accessibility = renderPixelSnapshot(
                          secondView
                              .environment(\.dynamicTypeSize, .accessibility5)
                              .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge),
                          width: 440,
                          height: 596
                      ),
                      let repeatedAccessibility = renderPixelSnapshot(
                          secondView
                              .environment(\.dynamicTypeSize, .accessibility5)
                              .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge),
                          width: 440,
                          height: 596
                      ) else {
                    failures.append("[\(currentTest)] settings snapshot failed to render")
                    return
                }

                expectEqual(first.width, 440)
                expectEqual(first.height, 596)
                expectEqual(first.opaquePixelCount, 440 * 596)
                expectEqual(first.fingerprint, repeated.fingerprint, "static settings renders should be byte-stable")
                expectEqual(accessibility.width, 440)
                expectEqual(accessibility.height, 596)
                expectEqual(accessibility.opaquePixelCount, 440 * 596)
                expectEqual(
                    accessibility.fingerprint,
                    repeatedAccessibility.fingerprint,
                    "maximum Dynamic Type settings renders should be byte-stable"
                )
                expect(
                    accessibility.fingerprint != first.fingerprint,
                    "maximum Dynamic Type should change the rendered settings type"
                )
            }

            test("ui.reduceMotionPreviewSnapshotIsStable") {
                let preview = AnimatedPetPreview(
                    kind: .cat,
                    pixel: 3,
                    accessory: .none,
                    reduceMotionOverride: true
                )
                guard let first = renderPixelSnapshot(preview, width: 120, height: 120),
                      let repeated = renderPixelSnapshot(preview, width: 120, height: 120) else {
                    failures.append("[\(currentTest)] reduced-motion preview snapshot failed to render")
                    return
                }

                expect(first.opaquePixelCount > 0, "reduced-motion preview should draw a static pet")
                expectEqual(first.fingerprint, repeated.fingerprint, "reduced-motion preview should not advance frames")
            }

            test("ui.popoverRendersEveryPhase") {
                let phases: [CapturePhase] = [.idle, .recording, .transcribing, .copied, .pasted, .error("Microphone unplugged")]
                for phase in phases {
                    let state = makeUIState(phase: phase)
                    expectRenders("brutal.\(phase.label)", makeBrutalPopover(state))
                }
            }

            test("ui.popoversRenderAtMaximumDynamicTypeWithLongContent") {
                let state = makeUIState()
                state.statusText = "Impossible de charger le modèle multilingue; 日本語の音声モデルを確認し、configuración de accesibilidad y permisos del micrófonoをもう一度確認してください."
                state.phase = .error("Le modèle local n'est pas disponible; reconnectez le stockage géré et réessayez sans perdre la transcription actuelle.")
                state.lastTranscript = "Esta es una transcripción deliberadamente larga avec du français, English context, 日本語の語彙, des nombres 12345 et des termes techniques YappYapp, LUMEX et CoreML pour tester le retour à la ligne sans troncature ni chevauchement."

                expectRenders(
                    "brutal.accessibility5.longContent",
                    makeBrutalPopover(state).environment(\.dynamicTypeSize, .accessibility5),
                    width: 440,
                    height: 596
                )
            }

            test("ui.modelsTabRendersDownloadStates") {
                // A whisper download mid-flight plus a parakeet download just
                // starting; rows must render the progress affordances.
                let state = makeUIState(downloads: ["small": 0.42, "parakeet-v3": 0.05])
                expectRenders("brutal.downloading", makeBrutalPopover(state).modelsTab)
            }

            test("ui.managedOfflineSetupRenders") {
                let state = makeUIState(allowModelDownloads: false)
                state.isModelReady = false
                state.isAccessibilityTrusted = false

                expectRenders("brutal.managedOffline.home", makeBrutalPopover(state).homeTab)
                expectRenders("brutal.managedOffline.models", makeBrutalPopover(state).modelsTab)
            }

            test("ui.petTabRendersStarterChooserAndEgg") {
                let chooser = makeUIState(starter: nil)
                expectRenders("brutal.starterChooser", makeBrutalPopover(chooser).petTab)

                let egg = makeUIState(starter: .crab, hatched: false)
                expectRenders("brutal.eggPhase", makeBrutalPopover(egg).petTab)
            }

            test("ui.hudsRenderAllStates") {
                let phases: [CapturePhase] = [
                    .idle, .recording, .transcribing, .pasted, .sentUnconfirmed,
                    .notDelivered(headline: "NOT PASTED", reason: "x"), .canceled, .error("x")
                ]
                for position in HUDPosition.allCases where position != .off {
                    let size = position.windowSize
                    for phase in phases {
                        let state = makeUIState(phase: phase)
                        state.config.hudPosition = position.rawValue
                        expectRenders("alwaysOn.\(position.rawValue).\(phase.label)", AlwaysOnHUDView(state: state), width: size.width, height: size.height)
                    }
                }

                let recording = makeUIState(phase: .recording)
                for vertical in [false, true] {
                    let size = BrutalistHUDView.size(vertical: vertical)
                    expectRenders("hud.brutal.vertical-\(vertical)", BrutalistHUDView(state: recording, vertical: vertical), width: size.width, height: size.height)
                }
            }

            test("ui.everyPetRendersInEveryForm") {
                let state = makeUIState()
                for kind in PetKind.allCases where kind != .none {
                    expectRenders("petView.\(kind.rawValue)", PetView(state: state, kind: kind, pixel: 2), width: 300, height: 110)
                    expectRenders("thumb.\(kind.rawValue)", PetThumb(kind: kind), width: 60, height: 60)
                    expectRenders("silhouette.\(kind.rawValue)", PetThumb(kind: kind, silhouette: true), width: 60, height: 60)
                    expectRenders("egg.\(kind.rawValue)", PetThumb(kind: kind, asEgg: true), width: 60, height: 60)
                    expectRenders("preview.\(kind.rawValue)", AnimatedPetPreview(kind: kind), width: 120, height: 120)
                }
            }

            test("ui.recapCardRenders") {
                let state = makeUIState()
                expectRenders("recapCard", RecapCardView(stats: state.petStats, kind: .cat), width: 420, height: 540)
            }

            test("pet.seasonalWardrobeIsDeterministic") {
                func date(_ m: Int, _ d: Int) -> Date {
                    Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d))!
                }
                expect(PetView.seasonalHat(for: date(12, 25)) != nil, "December has Santa")
                expect(PetView.seasonalHat(for: date(10, 28)) != nil, "late October has pumpkin")
                expect(PetView.seasonalHat(for: date(2, 14)) != nil, "Valentine window has heart")
                expect(PetView.seasonalHat(for: date(1, 1)) != nil, "New Year has popper")
                expect(PetView.seasonalHat(for: date(7, 15)) != nil, "summer has shades")
                expect(PetView.seasonalHat(for: date(4, 3)) == nil, "ordinary day has no festive hat")
            }
        }
    }

    static func run() -> Never {
        wavWriterTests()
        normalizerTests()
        recordingTests()
        fillerWordsTests()
        glossaryTests()
        configTests()
        brutalDesignSystemTests()
        uiAccessibilityContractTests()
        languageCatalogTests()
        permissionDiagnosticsTests()
        clipboardTests()
        pasteOutcomePresenterTests()
        statusFlavorTests()
        petStatsTests()
        timeSavedTests()
        petEventPresenterTests()
        stateTests()
        modelCatalogTests()
        modelReadinessPresenterTests()
        modelActivationPlannerTests()
        modelDownloadPresenterTests()
        setupReadinessPresenterTests()
        staleAccessibilityDetectorTests()
        modelDownloadTests()
        warmServerTests()
        spriteTests()
        uxStateTests()
        uiRenderTests()

        // Per-track suites (SelfTests+<Track>.swift).
        firstrunTrackTests()

        pipelineTrackTests()

        audioTrackTests()

        enginesTrackTests()

        hotkeyTrackTests()

        petTrackTests()

        configTrackTests()

        releaseTrackTests()

        a11yTrackTests()

        cleanupTrackTests()

        commandsTrackTests()

        profilesTrackTests()

        snippetsTrackTests()

        numbersTrackTests()

        supportTrackTests()
        setupTrackTests()
        onboardingTrackTests()

        livefileTrackTests()

        l10nTrackTests()

        warmTrackTests()
        modelsTrackTests()

        if failures.isEmpty {
            print("SELF-TEST PASSED: \(passed) assertions")
            exit(0)
        } else {
            print("SELF-TEST FAILED: \(failures.count) failures, \(passed) assertions passed")
            for failure in failures {
                print("  FAIL \(failure)")
            }
            exit(1)
        }
    }
}
#endif
