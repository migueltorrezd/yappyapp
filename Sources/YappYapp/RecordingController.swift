import AppKit
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case microphoneDenied
    case recorderUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            L10n.tr("YappYapp needs the mic. Allow it in System Settings > Privacy & Security > Microphone.")
        case .recorderUnavailable:
            L10n.tr("The mic didn't start. Pick another mic in Setup.")
        }
    }
}

// SUPER-FAST-MODE: fixed-capacity circular buffer of 16 kHz mono Int16 samples.
// While the warm capture session runs, the audio thread appends every converted
// buffer here; when a dictation starts, the ring's contents are prepended to
// the WAV so speech that began just before the hotkey is never clipped.
// Pure value logic (no locking — the owner synchronizes) so the self-tests can
// pin wrap-around and ordering.
struct Int16RingBuffer {
    private(set) var storage: [Int16]
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Int16](repeating: 0, count: max(1, capacity))
    }

    mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
            count = min(count + 1, storage.count)
        }
    }

    mutating func append(contentsOf samples: [Int16]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Oldest-to-newest snapshot of everything currently buffered.
    func snapshot() -> [Int16] {
        guard count > 0 else { return [] }
        if count < storage.count {
            return Array(storage[0..<count])
        }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
    }
}

/// Bridges AVFoundation's `@Sendable` converter callback without capturing a
/// mutable local or transferring an `AVAudioPCMBuffer` directly. The buffer is
/// immutable for the callback lifetime and consumption is lock-protected.
private final class SingleAudioBufferProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !consumed else {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
    }
}

// Every cross-thread field is protected by `levelLock`; capture callbacks run
// on `captureQueue`, while lifecycle reads/writes may originate on MainActor.
final class RecordingController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Recordings shorter than this are discarded as accidental toggles.
    static let minimumFrames = 4000  // 0.25s at 16 kHz
    static let routeChangeRecoveryDebounce: TimeInterval = 0.8
    static let routeChangeSilenceTolerance: TimeInterval = 0.75
    /// ROUTE-CHANGE-FIX (wiredRouteChange): capture-session route-change
    /// observation is the shipped recovery path — see observeCaptureRouteChanges
    /// below and the runtime RouteChangeTest harness. (A hand-maintained
    /// `static let = true` used to live here purely for a self-test to assert;
    /// that proved nothing and was removed. The real recovery decision is the
    /// pure shouldFinishAfterRouteChange, which the self-tests do exercise.)

    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "app.yappyapp.YappYapp.audio-capture")
    private var writer: WAVFileWriter?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )
    private var currentURL: URL?
    private var startedAt: Date?
    // FIX(observerGeneration): route-change observers are keyed by the session
    // generation that installed them, not held in one flat array. Two starts can
    // run startCaptureSession() concurrently off-main (gen N suspended on
    // requestAccess while gen N+1 goes live); a flat array let a superseded gen N
    // teardown strip gen N+1's LIVE observers. Keying by generation means a
    // teardown only ever removes its own.
    private var captureObservers: [Int: [NSObjectProtocol]] = [:]
    private var recoveryWorkItem: DispatchWorkItem?
    /// Called on the main queue when a route change, a stopped session, a
    /// buffer stall or system sleep ends capture; the owner should end the
    /// recording gracefully with what was captured and show `reason.message`.
    var onIrrecoverableInterruption: ((CaptureInterruption) -> Void)?

    // LIVE-PREVIEW: receives every 16 kHz mono sample that reaches the WAV
    // (never the warm pre-roll), on the capture queue. Memory only.
    private var liveSampleTapValue: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)?
    var liveSampleTap: (@Sendable (UnsafeBufferPointer<Int16>) -> Void)? {
        get { levelLock.lock(); defer { levelLock.unlock() }; return liveSampleTapValue }
        set { levelLock.lock(); liveSampleTapValue = newValue; levelLock.unlock() }
    }
    // FIX recRace / FIX startRace: levelLock now guards ALL cross-thread
    // recording state — writer/converter/levels AND the session-lifecycle
    // fields (captureSession, currentURL, startedAt, captureObservers) plus the
    // session-generation token below. startCaptureSession() runs off-main while
    // stop()/duration read on main, so every one of these needs the lock.
    private let levelLock = NSLock()
    private var latestLevel: Float = 0
    private var peakDecibelsValue: Float = -120
    private var lastBufferAt: Date?
    // YA-56: read on the audio thread, written by start(); guarded by levelLock.
    private var meterFloor: Float = -42
    // FIX startRace: `liveSession` is the generation authorized to go live and
    // `liveSessionValid` whether one is still authorized. beginSession() is
    // called on the main thread BEFORE the async start() runs, so a stop() /
    // cancel() that lands in the gap where start() is suspended on
    // requestAccess (or between startRunning and the field commit) can flip
    // liveSessionValid=false and force the in-flight start to tear itself down.
    private var liveSession = 0
    private var liveSessionValid = false
    /// Standalone probe callers (diagnostics, route-change test) drive start()
    /// directly without the main-actor toggle machine, so they self-authorize a
    /// generation from here instead of via beginSession(). YA-56: levelLock.
    private var internalSession = 0

    // YA-21: buffer watchdog and interruption bookkeeping, guarded by levelLock.
    // `armedAt` is when the current writer went live; `interruptionReported`
    // makes sure the owner hears about one dead recording exactly once.
    private var armedAt: Date?
    private var watchdogTimer: DispatchSourceTimer?
    private var interruptionReported = false
    private var systemAsleep = false
    private var systemObservers: [NSObjectProtocol] = []

    // Source routing: buffers from the warm session and from a cold session
    // share this delegate, so each buffer is matched to the output that owns
    // the current sink. A warm session that comes up while a cold recording
    // runs can never double the audio. Guarded by levelLock.
    private var coldOutputID: ObjectIdentifier?
    private var warmOutputID: ObjectIdentifier?
    private var writerIsWarm = false

    // YA-23: ring samples prepended to the current WAV, and the value from the
    // last stop() so the owner's silence check can skip the pre-roll.
    private var preRollFrames = 0
    private var lastStoppedPreRollFramesValue = 0

    // YA-53: the start chime is trimmed off the head of the WAV; the stop
    // chime is kept out of the warm ring until it has finished.
    private var chimeTrimmer = ChimeTrimmer()
    private var warmRingSuppressedUntil: Date?

    /// YA-57: capture sessions stop here, never on the main thread.
    private static let teardownQueue = DispatchQueue(label: "app.yappyapp.YappYapp.capture-teardown")

    // SUPER-FAST-MODE: a persistent warm capture session plus a ~1.5s ring of
    // converted 16 kHz samples. While warm and idle, captureOutput feeds the
    // ring; start() then attaches a writer synchronously (no mic spin-up) and
    // prepends the ring so speech from just before the hotkey survives. All
    // fields below are guarded by levelLock. The ring only fills while NO
    // writer is attached — otherwise the tail of one dictation would be
    // prepended to the next.
    static let warmRingCapacity = 24_000  // 1.5s at 16 kHz
    private var warmHandle: WarmCaptureSessionHandle?
    private var warmBuiltForUID: String?  // nil = system default device
    private var warmBuffering = false
    private var warmRing = Int16RingBuffer(capacity: RecordingController.warmRingCapacity)

    // YA-04: every warm-session build and teardown runs on this one serial
    // queue, and always reconciles toward the LATEST requested state, so two
    // refreshes can never both build a session and a disable can never be
    // overtaken by an older enable. The desired state is guarded by levelLock.
    private let warmQueue = DispatchQueue(label: "app.yappyapp.YappYapp.warm-session")
    private var warmDesiredEnabled = false
    private var warmDesiredUID: String?
    private var warmReconcilePending = false
    /// Only touched on warmQueue.
    private var defaultInputObserver: DefaultInputDeviceObserver?

    /// Builds a warm session for a requested device UID (nil = system
    /// default). nil here means the real AVCaptureSession; self-tests inject a
    /// fake. Set before the first setWarmMode call.
    var warmSessionFactory: (@Sendable (String?) -> WarmCaptureSessionHandle?)?
    /// Warm mode must never be the thing that triggers a permission prompt.
    var warmAuthorizationCheck: @Sendable () -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    /// YA-22: the current system default input UID.
    var systemDefaultInputUID: @Sendable () -> String? = {
        AudioInputDevices.defaultInputUID()
    }

    // FIX recRace: writer/converter guarded by levelLock (audio thread vs main).
    private var lockedWriter: WAVFileWriter? {
        levelLock.lock(); defer { levelLock.unlock() }
        return writer
    }
    private func setWriterLocked(_ newValue: WAVFileWriter?) {
        levelLock.lock(); writer = newValue; levelLock.unlock()
    }
    private func setConverterLocked(_ newValue: AVAudioConverter?) {
        levelLock.lock(); converter = newValue; levelLock.unlock()
    }

    // FIX startRace: authorize `generation` to go live and implicitly invalidate
    // any earlier in-flight start (which captured a smaller generation). The
    // owner MUST call this on the main thread before dispatching the async
    // start(), so a stop()/cancel() in the async gap can invalidate it.
    func beginSession(_ generation: Int) {
        levelLock.lock()
        liveSession = generation
        liveSessionValid = true
        levelLock.unlock()
    }

    private func isSessionCurrent(_ generation: Int) -> Bool {
        levelLock.lock(); defer { levelLock.unlock() }
        return liveSessionValid && liveSession == generation
    }

    // FIX startRace: captureObservers is written by startCaptureSession() off the
    // main thread and read/cleared by stop() on main, so its access is locked too.
    private func setCaptureObservers(_ observers: [NSObjectProtocol], generation: Int) {
        levelLock.lock(); captureObservers[generation] = observers; levelLock.unlock()
    }

    // FIX(observerGeneration): remove only the observers a specific generation
    // installed, so a superseded start's teardown can never strip a newer live
    // session's observers.
    private func removeCaptureObservers(generation: Int) {
        levelLock.lock()
        let observers = captureObservers.removeValue(forKey: generation)
        levelLock.unlock()
        for observer in observers ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // FIX(observerGeneration): stop() tears down the whole recording, so it drops
    // every generation's observers regardless of which one is live.
    private func removeAllCaptureObservers() {
        levelLock.lock()
        let all = captureObservers
        captureObservers = [:]
        levelLock.unlock()
        for observers in all.values {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Loudest input seen since recording started, in dBFS. Stays near -120
    /// when the microphone delivers nothing but digital silence.
    var peakDecibels: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return peakDecibelsValue
    }

    var duration: TimeInterval {
        // FIX startRace: startedAt is written off-main by startCaptureSession()
        // and cleared by stop(); the level timer reads this on main every frame.
        levelLock.lock()
        let startedAt = self.startedAt
        levelLock.unlock()
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Normalized microphone input level (0...1) for live waveform rendering.
    var meterLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    private func resetPeak() {
        levelLock.lock()
        peakDecibelsValue = -120
        levelLock.unlock()
    }

    /// YA-23: `preRollFrames` (the warm ring prepended at start) never
    /// counts toward the accidental-toggle floor.
    static func shouldKeepRecording(frameCount: Int, preRollFrames: Int = 0) -> Bool {
        frameCount - max(0, preRollFrames) >= minimumFrames
    }

    static func normalizedMeterLevel(rms: Float, meterFloor: Float) -> (level: Float, decibels: Float) {
        let decibels = 20 * log10(max(rms, 0.000_01))
        let safeFloor = min(meterFloor, -0.000_01)
        let clamped = min(max(decibels, safeFloor), 0)
        let normalized = (clamped - safeFloor) / -safeFloor

        return (normalized, decibels)
    }

    static func shouldFinishAfterRouteChange(secondsSinceLastBuffer: TimeInterval?) -> Bool {
        guard let secondsSinceLastBuffer else { return true }
        return secondsSinceLastBuffer >= routeChangeSilenceTolerance
    }

    func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MIC-LIVE-VERIFY: the guided microphone repair loop reads this each tick to
    // detect a grant made in the system dialog or in System Settings without
    // triggering another permission prompt.
    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func start(session: Int? = nil, preferredDeviceUID: String? = nil, meterFloor: Float = -42) async throws {
        // FIX startRace: adopt the generation the owner authorized via
        // beginSession(); standalone callers (no session passed) self-authorize.
        let generation: Int
        if let session {
            generation = session
        } else {
            generation = levelLock.withLock {
                internalSession += 1
                return internalSession
            }
            beginSession(generation)
        }

        guard await requestMicrophoneAccess() else {
            throw RecordingError.microphoneDenied
        }

        levelLock.withLock { self.meterFloor = meterFloor }
        resetPeak()
        installSystemObserversIfNeeded()

        // SUPER-FAST-MODE: if the warm session is live, attach a writer
        // synchronously and prepend the ring — no capture spin-up at all.
        if startFromWarmSession(generation: generation) {
            return
        }

        try startCaptureSession(preferredDeviceUID: preferredDeviceUID, generation: generation)
    }

    // MARK: - Super Fast Mode (warm mic + ring buffer)

    var isWarmSessionRunning: Bool {
        levelLock.lock(); defer { levelLock.unlock() }
        return warmHandle?.isRunning == true
    }

    /// Enable or disable the warm capture session. Cheap and safe from any
    /// thread: it records the requested state and lets the serial warm queue
    /// reconcile toward it. While a dictation is in flight the reconcile is
    /// deferred until stop(), so a mid-recording settings flip can never yank
    /// the microphone out from under a live writer.
    func setWarmMode(enabled: Bool, preferredDeviceUID: String?) {
        levelLock.lock()
        warmDesiredEnabled = enabled
        warmDesiredUID = preferredDeviceUID
        levelLock.unlock()
        warmQueue.async { [weak self] in self?.reconcileWarmSession() }
    }

    /// Blocks until every queued warm-session change has been applied. For
    /// tests and diagnostics; never call it from the warm queue.
    func waitForWarmSessionWork() {
        warmQueue.sync {}
    }

    /// YA-22: the system default input changed. Rebuild the warm session on
    /// the new default between dictations (deferred while recording).
    func defaultInputDidChange() {
        warmQueue.async { [weak self] in self?.reconcileWarmSession() }
    }

    private func reconcileWarmSession() {
        dispatchPrecondition(condition: .onQueue(warmQueue))

        levelLock.lock()
        if writer != nil {
            warmReconcilePending = true
            levelLock.unlock()
            return
        }
        let enabled = warmDesiredEnabled && !systemAsleep
        let requestedUID = warmDesiredUID
        let handle = warmHandle
        let builtForUID = warmBuiltForUID
        levelLock.unlock()

        guard enabled else {
            teardownWarmSessionIfIdle()
            defaultInputObserver?.invalidate()
            defaultInputObserver = nil
            return
        }
        guard warmAuthorizationCheck() else { return }

        updateDefaultInputObserver(followingDefault: requestedUID == nil)

        let needsRebuild = WarmSessionPlanner.needsRebuild(
            isRunning: handle?.isRunning == true,
            builtForUID: builtForUID,
            actualDeviceUID: handle?.deviceUID,
            requestedUID: requestedUID,
            systemDefaultUID: requestedUID == nil ? systemDefaultInputUID() : nil
        )
        guard needsRebuild, teardownWarmSessionIfIdle() else { return }

        let built: WarmCaptureSessionHandle?
        if let warmSessionFactory {
            built = warmSessionFactory(requestedUID)
        } else {
            built = makeLiveWarmSession(preferredDeviceUID: requestedUID)
        }
        guard let built else { return }

        levelLock.lock()
        warmHandle = built
        warmBuiltForUID = requestedUID
        warmOutputID = (built as? LiveWarmCaptureSession).map { ObjectIdentifier($0.output) }
        warmBuffering = true
        warmRing.removeAll()
        levelLock.unlock()
    }

    private func updateDefaultInputObserver(followingDefault: Bool) {
        // Fake sessions in self-tests never touch CoreAudio listeners.
        guard followingDefault, warmSessionFactory == nil else {
            defaultInputObserver?.invalidate()
            defaultInputObserver = nil
            return
        }
        guard defaultInputObserver == nil else { return }
        defaultInputObserver = DefaultInputDeviceObserver { [weak self] in
            self?.defaultInputDidChange()
        }
    }

    /// Detaches and stops the warm session unless a warm-started dictation is
    /// still writing from it. Returns false (and defers) in that case.
    @discardableResult
    private func teardownWarmSessionIfIdle() -> Bool {
        levelLock.lock()
        if writer != nil && writerIsWarm {
            warmReconcilePending = true
            levelLock.unlock()
            return false
        }
        let handle = warmHandle
        warmHandle = nil
        warmBuiltForUID = nil
        warmOutputID = nil
        warmBuffering = false
        warmRing.removeAll()
        levelLock.unlock()

        handle?.stop()
        return true
    }

    private func makeLiveWarmSession(preferredDeviceUID: String?) -> WarmCaptureSessionHandle? {
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = Self.captureDevice(preferredDeviceUID: preferredDeviceUID, systemDefaultUID: systemDefaultInputUID()),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(output)
        session.commitConfiguration()

        let live = LiveWarmCaptureSession(session: session, output: output, deviceUID: device.uniqueID)

        // While idle-warm: a runtime error, a disconnect or a session that
        // stopped on its own kills the warm session; rebuild it. During a
        // warm-started recording the same signals route into the graceful
        // finish instead.
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] notification in
            guard let self else { return }
            let usingWarm: Bool = {
                self.levelLock.lock(); defer { self.levelLock.unlock() }
                return self.writer != nil && self.writerIsWarm
            }()
            if usingWarm {
                let reason: CaptureInterruption = notification.name == .AVCaptureSessionDidStopRunning
                    ? .sessionStopped : .deviceChanged
                self.scheduleRecovery(reason)
            } else {
                self.restartWarmSessionAfterFailure()
            }
        }
        live.setObservers([
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main, using: handler),
            center.addObserver(forName: .AVCaptureSessionDidStopRunning, object: session, queue: .main, using: handler),
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main, using: handler),
        ])
        session.startRunning()
        installSystemObserversIfNeeded()
        return live
    }

    private func restartWarmSessionAfterFailure() {
        // Rebuild on the serial queue. If the preferred device vanished, the
        // builder falls back to the system default rather than staying
        // silently cold.
        warmQueue.async { [weak self] in
            guard let self, self.teardownWarmSessionIfIdle() else { return }
            self.reconcileWarmSession()
        }
    }

    /// Resolves the device to open: the requested UID, then the CoreAudio
    /// system default, then AVFoundation's default.
    private static func captureDevice(preferredDeviceUID: String?, systemDefaultUID: String?) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if let preferredDeviceUID, let match = devices.first(where: { $0.uniqueID == preferredDeviceUID }) {
            return match
        }
        if let systemDefaultUID, let match = devices.first(where: { $0.uniqueID == systemDefaultUID }) {
            return match
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Attach a writer to the already-running warm session. Returns true when
    /// this start was fully handled (including the superseded-while-suspended
    /// case); false means the caller should fall back to the cold path.
    private func startFromWarmSession(generation: Int) -> Bool {
        guard isWarmSessionRunning else { return false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappyapp-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        guard let createdWriter = try? WAVFileWriter(url: url, sampleRate: 16_000, channels: 1) else {
            return false
        }
        let timer = makeWatchdogTimer()

        levelLock.lock()
        guard liveSessionValid && liveSession == generation, warmHandle?.isRunning == true else {
            let stillWarm = warmHandle?.isRunning == true
            levelLock.unlock()
            timer.cancel()
            createdWriter.finalize()
            cleanup(url)
            // Superseded start: handled (nothing live). Warm session died in
            // the gap: let the cold path try instead.
            return !stillWarm ? false : true
        }
        // Prepend the ring inside the lock so no live buffer can be appended
        // ahead of it: the audio thread blocks on this same lock. ~48 KB max,
        // sub-millisecond.
        let ringSamples = warmRing.snapshot()
        warmRing.removeAll()
        if !ringSamples.isEmpty {
            Self.appendSamples(ringSamples, to: createdWriter, format: targetFormat)
        }
        writer = createdWriter
        writerIsWarm = true
        preRollFrames = ringSamples.count
        currentURL = url
        // The recording effectively began when the oldest ring sample was
        // captured; the duration display uses this. The accidental-toggle
        // floor and the silence check use post-hotkey frames only (YA-23).
        startedAt = Date().addingTimeInterval(-Double(ringSamples.count) / 16_000)
        armWatchdogLocked(timer)
        // captureSession stays nil on purpose: stop() must never stopRunning
        // the warm session — it just detaches the writer.
        levelLock.unlock()
        return true
    }

    private static func appendSamples(_ samples: [Int16], to writer: WAVFileWriter, format: AVAudioFormat?) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData?[0] else {
            return
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        writer.append(buffer)
    }

    private func startCaptureSession(preferredDeviceUID: String?, generation: Int) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = Self.captureDevice(preferredDeviceUID: preferredDeviceUID, systemDefaultUID: nil) else {
            throw RecordingError.recorderUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecordingError.recorderUnavailable
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.recorderUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappyapp-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let createdWriter = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)

        // FIX startRace: if a stop()/cancel() (or newer start) already superseded
        // us while we were suspended on requestAccess, never touch the mic — just
        // finalize and delete the orphan WAV we just created.
        guard isSessionCurrent(generation) else {
            createdWriter.finalize()
            cleanup(url)
            return
        }

        observeCaptureRouteChanges(of: session, input: input, generation: generation)
        session.startRunning()
        let timer = makeWatchdogTimer()

        // Publish the session-lifecycle fields only if still current, atomically
        // under the lock, so a superseded start can never clobber a newer
        // session's captureSession/writer/currentURL/startedAt.
        let committed: Bool = {
            levelLock.lock()
            defer { levelLock.unlock() }
            guard liveSessionValid && liveSession == generation else { return false }
            writer = createdWriter
            writerIsWarm = false
            preRollFrames = 0
            coldOutputID = ObjectIdentifier(output)
            currentURL = url
            startedAt = Date()
            captureSession = session
            armWatchdogLocked(timer)
            return true
        }()

        guard committed else {
            // Superseded after we went live (a stop() landed between startRunning
            // and this commit). Tear down the mic we just started and delete the
            // orphan WAV so no running session outlives its stop and no temp file
            // leaks. (session was never published, so stop() could not see it.)
            // FIX(observerGeneration): remove only THIS generation's observers so
            // a newer live session's observers are never stripped.
            removeCaptureObservers(generation: generation)
            timer.cancel()
            session.stopRunning()
            createdWriter.finalize()
            cleanup(url)
            return
        }
    }

    /// ROUTE-CHANGE-FIX (wiredRouteChange): the AVCaptureSession path is what
    /// ships, so route-change recovery must hang off capture-session and
    /// device notifications, not .AVAudioEngineConfigurationChange. On a
    /// runtime error, input-device disconnect or a session that stops on its
    /// own (YA-21), the session stops delivering buffers; we finish gracefully
    /// with whatever was captured.
    private func observeCaptureRouteChanges(of session: AVCaptureSession, input: AVCaptureDeviceInput, generation: Int) {
        // FIX(observerGeneration): install under this generation's key. No global
        // clear first — each generation installs exactly once and removes exactly
        // its own key on teardown/stop, so nothing leaks and no sibling is stripped.
        let center = NotificationCenter.default
        let runtimeError = center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] _ in self?.scheduleRecovery(.deviceChanged) }
        let interrupted = center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in self?.scheduleRecovery(.deviceChanged) }
        let stopped = center.addObserver(
            forName: .AVCaptureSessionDidStopRunning, object: session, queue: .main
        ) { [weak self] _ in self?.scheduleRecovery(.sessionStopped) }
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: input.device, queue: .main
        ) { [weak self] _ in self?.scheduleRecovery(.deviceChanged) }
        setCaptureObservers([runtimeError, interrupted, stopped, disconnected], generation: generation)
    }

    // MARK: - YA-21 watchdog and system sleep

    private func makeWatchdogTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + CaptureWatchdog.tickInterval,
            repeating: CaptureWatchdog.tickInterval
        )
        timer.setEventHandler { [weak self] in self?.evaluateWatchdog() }
        // Activated right away: a dispatch source released while still
        // suspended crashes. Every path that does not arm it cancels it.
        timer.activate()
        return timer
    }

    /// Caller holds levelLock and has just attached the writer.
    private func armWatchdogLocked(_ timer: DispatchSourceTimer) {
        watchdogTimer?.cancel()
        watchdogTimer = timer
        armedAt = Date()
        lastBufferAt = nil
        interruptionReported = false
        chimeTrimmer.reset()
    }

    private func evaluateWatchdog() {
        levelLock.lock()
        let armedAt = self.armedAt
        let lastBufferAt = self.lastBufferAt
        let hasWriter = writer != nil
        levelLock.unlock()

        guard hasWriter, let armedAt else { return }
        if CaptureWatchdog.shouldRecover(now: Date(), armedAt: armedAt, lastBufferAt: lastBufferAt) {
            reportInterruption(.stalled)
        }
    }

    /// Main queue only. Tells the owner once per recording.
    private func reportInterruption(_ reason: CaptureInterruption) {
        levelLock.lock()
        guard writer != nil, !interruptionReported else {
            levelLock.unlock()
            return
        }
        interruptionReported = true
        levelLock.unlock()
        onIrrecoverableInterruption?(reason)
    }

    private func installSystemObserversIfNeeded() {
        levelLock.lock()
        guard systemObservers.isEmpty else {
            levelLock.unlock()
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        systemObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleWillSleep()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleDidWake()
            },
        ]
        levelLock.unlock()
    }

    /// The Mac is going to sleep: end a live dictation with what was captured
    /// and turn the warm microphone off until wake.
    func handleWillSleep() {
        reportInterruption(.systemSleep)
        levelLock.lock()
        systemAsleep = true
        levelLock.unlock()
        warmQueue.async { [weak self] in self?.reconcileWarmSession() }
    }

    func handleDidWake() {
        levelLock.lock()
        systemAsleep = false
        levelLock.unlock()
        warmQueue.async { [weak self] in self?.reconcileWarmSession() }
    }

    // MARK: - YA-53 chimes

    /// The start chime just began playing. When it can reach the microphone
    /// (built-in speakers), drop that much audio from the head of the live
    /// recording so the chime never lands in the WAV.
    func excludeStartChime(
        duration: TimeInterval,
        chimeReachesMicrophone: Bool = AudioInputDevices.defaultOutputIsBuiltIn()
    ) {
        guard chimeReachesMicrophone else { return }
        levelLock.lock()
        if writer != nil {
            chimeTrimmer.arm(samples: ChimeTrimmer.sampleCount(forChimeDuration: duration))
        }
        levelLock.unlock()
    }

    /// The stop chime just began playing. Keep it out of the warm pre-roll so
    /// a quick next dictation never starts with the previous stop chime.
    func suppressWarmPreRoll(for duration: TimeInterval, now: Date = Date()) {
        levelLock.lock()
        warmRing.removeAll()
        warmRingSuppressedUntil = now.addingTimeInterval(duration + ChimeTrimmer.latencyMargin)
        levelLock.unlock()
    }

    /// Ring samples prepended to the most recent stopped recording. The
    /// owner's silence check skips them so pre-roll noise cannot pass as
    /// speech (YA-23).
    var lastStoppedPreRollFrames: Int {
        levelLock.lock(); defer { levelLock.unlock() }
        return lastStoppedPreRollFramesValue
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // SUPER-FAST-MODE: buffers flow while a writer is attached OR while the
        // warm session is idling into the ring. Each buffer only reaches the
        // sink its own session owns.
        let outputID = ObjectIdentifier(output)
        levelLock.lock()
        let fromWarm = outputID == warmOutputID
        let fromCold = outputID == coldOutputID
        let toWriter = writer != nil && ((fromWarm && writerIsWarm) || (fromCold && !writerIsWarm))
        let toRing = fromWarm && writer == nil && warmBuffering
        levelLock.unlock()
        guard toWriter || toRing,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return
        }

        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, bufferListSize > 0 else { return }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  bufferListNoCopy: audioBufferList,
                  deallocator: nil
              ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        process(buffer: buffer, toWriter: toWriter)
    }

    private func scheduleRecovery(_ reason: CaptureInterruption) {
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishIfRouteChangeStoppedAudio(reason)
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeChangeRecoveryDebounce, execute: workItem)
    }

    private func finishIfRouteChangeStoppedAudio(_ reason: CaptureInterruption) {
        guard lockedWriter != nil else { return }

        levelLock.lock()
        let lastBufferAt = self.lastBufferAt
        levelLock.unlock()

        let secondsSinceLastBuffer = lastBufferAt.map { Date().timeIntervalSince($0) }
        guard Self.shouldFinishAfterRouteChange(secondsSinceLastBuffer: secondsSinceLastBuffer) else {
            return
        }

        reportInterruption(reason)
    }

    func stop() -> URL? {
        // FIX startRace: invalidate any in-flight start FIRST, then read+clear the
        // session-lifecycle fields atomically. A start still suspended on
        // requestAccess (or sitting between startRunning and its commit) sees
        // liveSessionValid=false and tears itself down instead of leaving a live
        // mic and an orphaned WAV after this stop() returns.
        levelLock.lock()
        liveSessionValid = false
        let session = captureSession
        captureSession = nil
        coldOutputID = nil
        let url = currentURL
        currentURL = nil
        startedAt = nil
        armedAt = nil
        let timer = watchdogTimer
        watchdogTimer = nil
        levelLock.unlock()

        timer?.cancel()
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil

        removeAllCaptureObservers()

        // YA-57: stopRunning blocks for a long time on Bluetooth inputs; never
        // on the caller's (main) thread. The session's buffers no longer match
        // coldOutputID, so nothing it still delivers reaches a sink.
        if let session {
            let box = CaptureSessionBox(session)
            Self.teardownQueue.async { box.session.stopRunning() }
        }

        setConverterLocked(nil)

        levelLock.lock()
        let writer = self.writer
        self.writer = nil
        writerIsWarm = false
        let preRoll = preRollFrames
        preRollFrames = 0
        lastStoppedPreRollFramesValue = preRoll
        chimeTrimmer.reset()
        latestLevel = 0
        lastBufferAt = nil
        // SUPER-FAST-MODE: drop anything buffered before/through this dictation
        // so the next warm start prepends only genuinely fresh audio.
        warmRing.removeAll()
        let reconcile = warmReconcilePending
        warmReconcilePending = false
        levelLock.unlock()
        writer?.finalize()

        // A warm-mode change or default-input switch that arrived mid-recording
        // lands now, between dictations.
        if reconcile {
            warmQueue.async { [weak self] in self?.reconcileWarmSession() }
        }

        // A header-only or near-empty WAV makes whisper's decoder fail, and a
        // sub-quarter-second recording is an accidental toggle anyway. YA-23:
        // judged on post-hotkey frames only, never the warm pre-roll.
        if let writer, !Self.shouldKeepRecording(frameCount: writer.frameCount, preRollFrames: preRoll) {
            cleanup(url)
            return nil
        }

        return url
    }

    func cleanup(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func process(buffer capturedBuffer: AVAudioPCMBuffer, toWriter: Bool) {
        // YA-55: average every channel instead of keeping channel 1 only.
        let buffer = AudioDownmix.monoAverage(of: capturedBuffer) ?? capturedBuffer
        updateLevel(from: buffer, marksLiveBuffer: toWriter)

        levelLock.lock()
        let writer = toWriter ? self.writer : nil
        let existingConverter = self.converter
        // SUPER-FAST-MODE: the ring only fills while no writer is attached —
        // otherwise the tail of one dictation would leak into the next, and
        // not while the stop chime is still sounding (YA-53).
        let ringSuppressed = warmRingSuppressedUntil.map { Date() < $0 } ?? false
        let feedRing = !toWriter && warmBuffering && self.writer == nil && !ringSuppressed
        levelLock.unlock()

        guard let targetFormat, writer != nil || feedRing else { return }
        let converter = Self.converterMatching(inputFormat: buffer.format, candidate: existingConverter)
            ?? AVAudioConverter(from: buffer.format, to: targetFormat)
        guard let converter else { return }
        setConverterLocked(converter)

        let ratio = 16_000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        let inputProvider = SingleAudioBufferProvider(buffer: buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            inputProvider.next(outStatus: outStatus)
        }

        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error, outBuffer.frameLength > 0 else { return }

        if let writer {
            let frames = Int(outBuffer.frameLength)
            levelLock.lock()
            let drop = chimeTrimmer.leadingSamplesToDrop(of: frames)
            let tap = liveSampleTapValue
            levelLock.unlock()
            if drop == 0 {
                writer.append(outBuffer)
            } else if drop < frames, let channel = outBuffer.int16ChannelData?[0] {
                let kept = Array(UnsafeBufferPointer(start: channel + drop, count: frames - drop))
                Self.appendSamples(kept, to: writer, format: outBuffer.format)
            }
            // LIVE-PREVIEW: the same post-chime samples, copied into memory.
            if let tap, drop < frames, let channel = outBuffer.int16ChannelData?[0] {
                tap(UnsafeBufferPointer(start: channel + drop, count: frames - drop))
            }
        } else if feedRing, let channel = outBuffer.int16ChannelData?[0] {
            levelLock.lock()
            // Re-check under the lock: a start() may have attached a writer
            // (and drained the ring) between our snapshot and here.
            if warmBuffering && self.writer == nil {
                warmRing.append(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            levelLock.unlock()
        }
    }

    private static func converterMatching(
        inputFormat: AVAudioFormat,
        candidate: AVAudioConverter?
    ) -> AVAudioConverter? {
        guard let candidate else { return nil }
        let format = candidate.inputFormat
        guard format.sampleRate == inputFormat.sampleRate,
              format.channelCount == inputFormat.channelCount,
              format.commonFormat == inputFormat.commonFormat,
              format.isInterleaved == inputFormat.isInterleaved else {
            return nil
        }
        return candidate
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer, marksLiveBuffer: Bool) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let stride = max(1, frames / 256)
        var sum: Float = 0
        var count = 0
        var index = 0

        // Some input devices (notably Bluetooth) deliver Int16 instead of
        // Float32; the meter must handle both or the waveform goes flat.
        if let floatData = buffer.floatChannelData?[0] {
            while index < frames {
                let sample = floatData[index]
                sum += sample * sample
                count += 1
                index += stride
            }
        } else if let intData = buffer.int16ChannelData?[0] {
            while index < frames {
                let sample = Float(intData[index]) / 32768
                sum += sample * sample
                count += 1
                index += stride
            }
        } else {
            return
        }

        // Default -42 dB floor keeps room noise near zero while speech (-30 to
        // -15 dB) lands in the upper half. Quiet voice boost lowers the floor
        // so whispers still move the waveform.
        let rms = sqrt(sum / Float(max(count, 1)))

        levelLock.lock()
        let meter = Self.normalizedMeterLevel(rms: rms, meterFloor: meterFloor)
        latestLevel = meter.level
        peakDecibelsValue = max(peakDecibelsValue, meter.decibels)
        // Only buffers that reach the live writer count as proof the
        // recording is alive (watchdog and route-change recovery).
        if marksLiveBuffer {
            lastBufferAt = Date()
        }
        levelLock.unlock()
    }
}

/// YA-57: carries an AVCaptureSession to the teardown queue.
private final class CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// YA-04: the real warm session. Owns its notification observers so a stop
/// removes them before stopRunning (a self-initiated stop never looks like a
/// failure).
private final class LiveWarmCaptureSession: WarmCaptureSessionHandle, @unchecked Sendable {
    let session: AVCaptureSession
    let output: AVCaptureAudioDataOutput
    let deviceUID: String?
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    init(session: AVCaptureSession, output: AVCaptureAudioDataOutput, deviceUID: String?) {
        self.session = session
        self.output = output
        self.deviceUID = deviceUID
    }

    var isRunning: Bool { session.isRunning }

    func setObservers(_ newValue: [NSObjectProtocol]) {
        lock.lock(); observers = newValue; lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = observers
        observers = []
        lock.unlock()
        for observer in current {
            NotificationCenter.default.removeObserver(observer)
        }
        session.stopRunning()
    }
}
