import Foundation

// SUPPORT (missing feature 6): the "Say something" mic check in guided setup
// and SETUP. A live level meter from the selected input, tuned for people who
// whisper. The audio is never saved and never transcribed: the capture goes
// through the normal RecordingController metering path, and the scratch file
// it writes is deleted the moment the check stops.

enum MicLevelVerdict: Equatable, Sendable {
    /// Not enough audio yet to judge.
    case listening
    case nothingHeard
    case tooQuiet
    case good
    case tooLoud
}

/// Turns level readings into a verdict. Pure, so self-tests drive it with
/// fake buffers and fixed readings.
struct MicLevelMeter: Equatable, Sendable {
    /// The check meters against a fixed floor so the verdict never depends on
    /// whether Quiet Voice Boost is on.
    static let floorDecibels: Float = -60
    /// Below this the mic hears only the room.
    static let nothingHeardBelow: Float = -54
    /// Whispers and soft voices land between the two.
    static let goodFrom: Float = -38
    /// Close to clipping.
    static let tooLoudFrom: Float = -4
    /// Readings needed before a live verdict (about half a second at 20 Hz).
    static let minimumReadings = 10
    static let smoothing: Float = 0.4

    private(set) var smoothedDecibels: Float = floorDecibels
    /// Loudest smoothed level so far. Smoothing keeps one click or bump from
    /// counting as speech.
    private(set) var loudestDecibels: Float = floorDecibels
    private(set) var readings = 0

    mutating func add(decibels: Float) {
        let clamped = min(max(decibels.isFinite ? decibels : Self.floorDecibels, Self.floorDecibels), 0)
        smoothedDecibels = readings == 0
            ? clamped
            : smoothedDecibels + (clamped - smoothedDecibels) * Self.smoothing
        loudestDecibels = max(loudestDecibels, smoothedDecibels)
        readings += 1
    }

    /// A normalized 0...1 meter reading taken against `floorDecibels`.
    mutating func add(normalizedLevel level: Float) {
        add(decibels: Self.decibels(fromNormalized: level))
    }

    mutating func reset() {
        self = MicLevelMeter()
    }

    /// 0...1 bar position for the current smoothed level.
    var barLevel: Float {
        RecordingController.normalizedMeterLevel(
            rms: Self.rms(fromDecibels: smoothedDecibels),
            meterFloor: Self.floorDecibels
        ).level
    }

    /// While listening, "nothing heard" stays "listening" so a user who has
    /// not spoken yet is not scolded. `finished` makes the verdict final.
    func verdict(finished: Bool) -> MicLevelVerdict {
        guard readings >= Self.minimumReadings else {
            return finished ? .nothingHeard : .listening
        }
        if loudestDecibels >= Self.tooLoudFrom { return .tooLoud }
        if loudestDecibels >= Self.goodFrom { return .good }
        if loudestDecibels >= Self.nothingHeardBelow { return .tooQuiet }
        return finished ? .nothingHeard : .listening
    }

    // MARK: - Buffer math (mirrors RecordingController.updateLevel)

    static func decibels(fromNormalized level: Float) -> Float {
        let clamped = min(max(level, 0), 1)
        return floorDecibels + clamped * -floorDecibels
    }

    static func rms(fromDecibels decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    /// RMS level in dBFS of Float32 samples, sampled with the same stride as
    /// the live meter.
    static func decibels(floatSamples samples: [Float]) -> Float {
        rmsDecibels(count: samples.count) { samples[$0] }
    }

    /// RMS level in dBFS of Int16 samples (Bluetooth inputs deliver these).
    static func decibels(int16Samples samples: [Int16]) -> Float {
        rmsDecibels(count: samples.count) { Float(samples[$0]) / 32768 }
    }

    private static func rmsDecibels(count: Int, sample: (Int) -> Float) -> Float {
        guard count > 0 else { return floorDecibels }
        let stride = max(1, count / 256)
        var sum: Float = 0
        var taken = 0
        var index = 0
        while index < count {
            let value = sample(index)
            sum += value * value
            taken += 1
            index += stride
        }
        let rms = sqrt(sum / Float(max(taken, 1)))
        return RecordingController.normalizedMeterLevel(rms: rms, meterFloor: floorDecibels).decibels
    }
}

enum MicCheckPhase: Equatable, Sendable {
    case idle
    case starting
    case listening
    case finished
    case failed(MicCheckFailure)
}

/// Why the mic check could not run. The words depend on where the card is.
enum MicCheckFailure: Equatable, Sendable {
    case micBlocked
    case wontOpen
}

/// What the check card says. Copy per PRODUCT.md: short, direct, no blame.
/// `pickerAbove` is true in SETUP > MICROPHONE, where the mic picker sits
/// right above the check; the first-run card on MIC points to Setup instead.
struct MicCheckCopy: Equatable {
    let headline: String
    let detail: String
    /// Offer to switch Quiet Voice Boost on.
    let offersBoost: Bool
    let tone: Tone

    enum Tone: Equatable {
        case neutral
        case good
        case warning
    }

    static var intro: String { L10n.tr("Talk the way you'll dictate, whispers too. Nothing is saved or transcribed.") }

    static func make(phase: MicCheckPhase, verdict: MicLevelVerdict, quietVoiceBoost: Bool, pickerAbove: Bool = false) -> MicCheckCopy {
        switch phase {
        case .idle:
            return MicCheckCopy(headline: L10n.tr("6-SECOND MIC TEST"), detail: intro, offersBoost: false, tone: .neutral)
        case .starting:
            return MicCheckCopy(headline: L10n.tr("OPENING THE MIC"), detail: intro, offersBoost: false, tone: .neutral)
        case .failed(let failure):
            return MicCheckCopy(headline: L10n.tr("MIC CHECK FAILED"), detail: message(for: failure, pickerAbove: pickerAbove), offersBoost: false, tone: .warning)
        case .listening, .finished:
            break
        }

        switch verdict {
        case .listening:
            return MicCheckCopy(headline: L10n.tr("LISTENING"), detail: L10n.tr("Say a sentence. The bar should move."), offersBoost: false, tone: .neutral)
        case .nothingHeard:
            return MicCheckCopy(
                headline: L10n.tr("NOTHING HEARD"),
                detail: pickerAbove
                    ? L10n.tr("Pick another mic above, then test again.")
                    : L10n.tr("Pick another mic in Setup > Microphone, then test again."),
                offersBoost: false,
                tone: .warning
            )
        case .tooQuiet:
            return MicCheckCopy(
                headline: L10n.tr("TOO QUIET"),
                detail: quietVoiceBoost
                    ? L10n.tr("Quiet Voice Boost is on and will help.")
                    : L10n.tr("Turn on Quiet Voice Boost. It helps."),
                offersBoost: !quietVoiceBoost,
                tone: .warning
            )
        case .good:
            return MicCheckCopy(headline: L10n.tr("GOOD"), detail: L10n.tr("Loud and clear."), offersBoost: false, tone: .good)
        case .tooLoud:
            return MicCheckCopy(headline: L10n.tr("VERY LOUD"), detail: L10n.tr("Move back a little or turn the mic down."), offersBoost: false, tone: .warning)
        }
    }

    static func failure(for error: Error) -> MicCheckFailure {
        if let recording = error as? RecordingError, case .microphoneDenied = recording {
            return .micBlocked
        }
        return .wontOpen
    }

    static func message(for failure: MicCheckFailure, pickerAbove: Bool) -> String {
        switch failure {
        case .micBlocked:
            L10n.tr("The mic is blocked. Allow it in System Settings > Privacy & Security > Microphone.")
        case .wontOpen:
            pickerAbove
                ? L10n.tr("That mic won't open. Pick another above.")
                : L10n.tr("That mic won't open. Pick another in Setup > Microphone.")
        }
    }
}

/// Where the check's levels come from. Production wraps its own
/// RecordingController; self-tests use a fake that never opens a mic.
protocol MicLevelSource: AnyObject, Sendable {
    /// Called on the main actor before `start`, so a `stop` that lands while
    /// the start is still pending cancels it.
    func prepare() -> Int
    func start(generation: Int, deviceUID: String?, meterFloor: Float) async throws
    /// Closes the mic and deletes the scratch audio. Safe to call twice.
    func stop()
    /// Normalized 0...1 level against the floor passed to `start`.
    var meterLevel: Float { get }
}

/// Its own RecordingController, so the check never shares state with a
/// dictation. The WAV it writes is removed on stop: never saved, never read.
final class RecorderMicLevelSource: MicLevelSource, @unchecked Sendable {
    private let recorder = RecordingController()
    private let lock = NSLock()
    private var generation = 0

    func prepare() -> Int {
        let next = lock.withLock {
            generation += 1
            return generation
        }
        recorder.beginSession(next)
        return next
    }

    func start(generation: Int, deviceUID: String?, meterFloor: Float) async throws {
        try await recorder.start(session: generation, preferredDeviceUID: deviceUID, meterFloor: meterFloor)
    }

    func stop() {
        let url = recorder.stop()
        recorder.cleanup(url)
    }

    var meterLevel: Float {
        recorder.meterLevel
    }
}

@MainActor
final class MicCheckController: ObservableObject {
    static let shared = MicCheckController()

    /// The check ends by itself so the mic is never left open.
    static let duration: TimeInterval = 6
    static let tickInterval: TimeInterval = 0.05

    @Published private(set) var phase: MicCheckPhase = .idle
    @Published private(set) var meter = MicLevelMeter()
    /// In memory only: true from a first-run launch until the user finishes
    /// or skips the guided step.
    @Published private(set) var guidedStepArmed = false

    private let makeSource: () -> MicLevelSource
    private let now: () -> Date
    private let schedulesTimer: Bool
    private var reusableSource: MicLevelSource?
    private var source: MicLevelSource?
    private var startedAt: Date?
    private var timer: Timer?
    private var runID = 0

    init(
        makeSource: @escaping () -> MicLevelSource = { RecorderMicLevelSource() },
        now: @escaping () -> Date = Date.init,
        schedulesTimer: Bool = true
    ) {
        self.makeSource = makeSource
        self.now = now
        self.schedulesTimer = schedulesTimer
    }

    var isRunning: Bool {
        phase == .starting || phase == .listening
    }

    var verdict: MicLevelVerdict {
        meter.verdict(finished: phase == .finished)
    }

    func copy(quietVoiceBoost: Bool, pickerAbove: Bool = false) -> MicCheckCopy {
        MicCheckCopy.make(phase: phase, verdict: verdict, quietVoiceBoost: quietVoiceBoost, pickerAbove: pickerAbove)
    }

    func armGuidedStep(isFirstRun: Bool) {
        guidedStepArmed = isFirstRun
    }

    func finishGuidedStep() {
        stop()
        guidedStepArmed = false
    }

    /// Whether the guided "Say something" card belongs on the MIC tab: armed
    /// by a first-run launch, microphone allowed, and no dictation running.
    static func showsGuidedCard(armed: Bool, microphoneAuthorized: Bool, phase: CapturePhase) -> Bool {
        armed && microphoneAuthorized && phase != .recording && phase != .transcribing
    }

    func start(deviceUID: String?) {
        stop()
        runID += 1
        let run = runID
        // One source for the controller's life: its recorder invalidates a
        // stale start by generation, and no observers pile up per run.
        let source = reusableSource ?? makeSource()
        reusableSource = source
        self.source = source
        meter.reset()
        phase = .starting
        startedAt = nil

        let generation = source.prepare()
        Task { @MainActor [weak self] in
            do {
                try await source.start(
                    generation: generation,
                    deviceUID: deviceUID,
                    meterFloor: MicLevelMeter.floorDecibels
                )
                guard let self else {
                    source.stop()
                    return
                }
                guard self.runID == run, self.phase == .starting else {
                    // Stopped while the mic was opening: close it again,
                    // unless a newer run already owns the mic.
                    if !self.isRunning { source.stop() }
                    return
                }
                self.startedAt = self.now()
                self.phase = .listening
                self.scheduleTimer()
            } catch {
                guard let self else {
                    source.stop()
                    return
                }
                guard self.runID == run else {
                    if !self.isRunning { source.stop() }
                    return
                }
                source.stop()
                self.source = nil
                self.phase = .failed(MicCheckCopy.failure(for: error))
            }
        }
    }

    /// Reads one level. The timer calls it in the app; tests call it directly.
    func tick() {
        guard phase == .listening, let source else { return }
        meter.add(normalizedLevel: source.meterLevel)
        if let startedAt, now().timeIntervalSince(startedAt) >= Self.duration {
            finish()
        }
    }

    /// Ends a running check and keeps its verdict on screen.
    func finish() {
        guard isRunning else { return }
        closeSource()
        phase = .finished
    }

    /// Ends any check and returns to the start. Used when the view goes away
    /// or a dictation begins.
    func stop() {
        runID += 1
        closeSource()
        phase = .idle
        meter.reset()
    }

    private func closeSource() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        source?.stop()
        source = nil
    }

    private func scheduleTimer() {
        guard schedulesTimer else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
