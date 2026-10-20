import Foundation

/// LIVE-PREVIEW (missing feature 13): while recording, the HUD shows the last
/// words heard so far. Parakeet only, opt-in, never pasted, nothing on disk.
/// The audio lives in a capped in-memory ring; a main-thread timer decodes the
/// latest window at most once per tick and skips a tick while one is running.
enum LivePreviewPolicy {
    static let sampleRate = 16_000
    /// Seconds of audio decoded per tick. The HUD shows ~60 characters, which
    /// is a few seconds of speech, so a short window keeps each decode cheap.
    static let windowSeconds = 10
    static let tickInterval: TimeInterval = 1.0
    /// A tick needs at least this much new audio since the last decode.
    static let minimumNewSamples = 6_400  // 0.4 s
    /// FluidAudio refuses less than 0.3 s; leave headroom.
    static let minimumWindowSamples = 8_000  // 0.5 s
    static let characterLimit = 60

    static var windowSamples: Int { windowSeconds * sampleRate }

    /// The preview runs only when the user turned it on and Parakeet is the
    /// selected engine. Whisper decodes are too slow to repeat every second.
    static func isEligible(config: AppConfig) -> Bool {
        config.livePreview && ModelCatalog.engine(for: config.modelPath) == .parakeet
    }
}

extension LivePreviewPolicy {
    /// The caption under the SETUP toggle.
    static func settingsNote(config: AppConfig) -> String {
        if ModelCatalog.engine(for: config.modelPath) != .parakeet {
            return L10n.tr("Works only with Parakeet models, so it stays off with this one.")
        }
        return L10n.tr("Your words appear in the indicator as you talk. The preview is never saved.")
    }
}

enum LivePreviewText {
    /// The last `limit` characters of `text`, cut at a word boundary when one
    /// is close, with a leading ellipsis when anything was dropped.
    static func tail(_ text: String, limit: Int = LivePreviewPolicy.characterLimit) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        var cut = String(collapsed.suffix(limit - 1))
        // Drop a leading partial word if a space shows up early enough.
        if let space = cut.firstIndex(of: " "),
           cut.distance(from: cut.startIndex, to: space) <= limit / 4 {
            cut = String(cut[cut.index(after: space)...])
        }
        return "…" + cut
    }
}

enum LivePreviewAudio {
    /// Peak below this is room noise, not speech. Matches the normalizer.
    static let silencePeak: Float = AudioSignalProfile.silenceReferencePeak
    static let targetPeak: Float = 0.9
    static let maxGain: Float = 40

    /// Converts Int16 PCM to the Float samples FluidAudio expects, lifting quiet
    /// speech the same way the final WAV is normalized. Returns nil for silence
    /// so a silent tick costs no decode.
    static func floats(from samples: [Int16]) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(Float(sample)) / 32768)
        }
        guard peak > silencePeak else { return nil }
        let gain = min(maxGain, max(1, targetPeak / peak))
        let scale = gain / 32768
        return samples.map { max(-1, min(1, Float($0) * scale)) }
    }
}

/// Thread-safe, fixed-size store of the most recent samples. The capture queue
/// appends; the main thread snapshots. Never touches the disk.
final class LivePreviewSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: Int16RingBuffer
    private var appended = 0

    init(capacity: Int = LivePreviewPolicy.windowSamples) {
        ring = Int16RingBuffer(capacity: capacity)
    }

    func append(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        ring.append(samples)
        appended += samples.count
        lock.unlock()
    }

    /// Oldest-to-newest window plus the running total of samples ever seen,
    /// so the scheduler can tell whether anything new arrived.
    func snapshot() -> (samples: [Int16], totalAppended: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (ring.snapshot(), appended)
    }

    func reset() {
        lock.lock()
        ring.removeAll()
        appended = 0
        lock.unlock()
    }
}

/// Decides, per tick, whether a decode should run. Pure, so the backpressure
/// rules are testable without audio or a model.
struct LivePreviewScheduler: Equatable {
    enum Decision: Equatable {
        case run
        case skipInFlight
        case skipNoNewAudio
        case skipTooShort
    }

    private(set) var lastDecodedTotal = 0
    private(set) var skippedInFlight = 0

    mutating func decide(totalAppended: Int, windowCount: Int, inFlight: Bool) -> Decision {
        if inFlight {
            skippedInFlight += 1
            return .skipInFlight
        }
        if windowCount < LivePreviewPolicy.minimumWindowSamples {
            return .skipTooShort
        }
        if totalAppended - lastDecodedTotal < LivePreviewPolicy.minimumNewSamples {
            return .skipNoNewAudio
        }
        lastDecodedTotal = totalAppended
        return .run
    }
}

/// Runs the preview for one recording session at a time. Main-thread only.
@MainActor
final class LivePreviewController {
    /// Decodes a window for the session's context (the Parakeet variant).
    typealias Decode = @Sendable ([Float], String) async -> String?

    private let decode: Decode
    private let publish: (String?) -> Void
    private let interval: TimeInterval
    private var buffer: LivePreviewSampleBuffer?
    private var context = ""
    private var scheduler = LivePreviewScheduler()
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    /// Bumped on every start and stop; a decode that finishes after its
    /// session ended sees a stale generation and drops its text.
    private var generation = 0

    private(set) var decodesStarted = 0

    init(
        interval: TimeInterval = LivePreviewPolicy.tickInterval,
        decode: @escaping Decode,
        publish: @escaping (String?) -> Void
    ) {
        self.interval = interval
        self.decode = decode
        self.publish = publish
    }

    var isRunning: Bool { buffer != nil }
    var isDecoding: Bool { inFlight != nil }
    var skippedTicks: Int { scheduler.skippedInFlight }

    /// Starts a session and returns the sink the recorder feeds. `useTimer`
    /// is false in tests, which call `tick()` themselves.
    @discardableResult
    func start(context: String, useTimer: Bool = true) -> LivePreviewSampleBuffer {
        stop()
        let buffer = LivePreviewSampleBuffer()
        self.buffer = buffer
        self.context = context
        scheduler = LivePreviewScheduler()
        decodesStarted = 0
        if useTimer {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return buffer
    }

    /// One scheduling step. Skips while a decode is running (backpressure).
    func tick() {
        guard let buffer else { return }
        let snapshot = buffer.snapshot()
        let decision = scheduler.decide(
            totalAppended: snapshot.totalAppended,
            windowCount: snapshot.samples.count,
            inFlight: inFlight != nil
        )
        guard decision == .run else { return }
        guard let floats = LivePreviewAudio.floats(from: snapshot.samples) else { return }

        decodesStarted += 1
        let session = generation
        let decode = self.decode
        let context = self.context
        inFlight = Task { [weak self] in
            let text = await decode(floats, context)
            guard let self, self.generation == session else { return }
            self.inFlight = nil
            if let text, !text.isEmpty {
                self.publish(LivePreviewText.tail(text))
            }
        }
    }

    /// Ends the session at once: no more ticks, the text clears, the buffer
    /// is dropped and any decode still running has its result ignored.
    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        inFlight?.cancel()
        inFlight = nil
        buffer?.reset()
        buffer = nil
        publish(nil)
    }
}
