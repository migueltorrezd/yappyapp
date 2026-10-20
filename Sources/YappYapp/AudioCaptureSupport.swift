@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Why a live recording had to end early. The owner finishes gracefully with
/// whatever was captured and shows `message` so the user knows what happened.
enum CaptureInterruption: Equatable {
    /// Runtime error, interruption or disconnect of the input device.
    case deviceChanged
    /// The capture session stopped running on its own.
    case sessionStopped
    /// No audio buffer arrived for longer than the watchdog allows.
    case stalled
    /// The Mac is going to sleep.
    case systemSleep

    var message: String {
        switch self {
        case .deviceChanged:
            L10n.tr("Mic changed. Transcribing what it caught.")
        case .sessionStopped:
            L10n.tr("Mic stopped. Transcribing what it caught.")
        case .stalled:
            L10n.tr("Mic went silent for 2 seconds. Transcribing what it caught.")
        case .systemSleep:
            L10n.tr("Your Mac is going to sleep. Transcribing what it caught.")
        }
    }
}

/// YA-21: pure decision for the capture watchdog. A session that delivered
/// buffers and then went silent for more than `stallLimit` is dead. Before the
/// first buffer, slow inputs (Bluetooth) get `startupGrace` to spin up.
enum CaptureWatchdog {
    static let stallLimit: TimeInterval = 2.0
    static let startupGrace: TimeInterval = 4.0
    static let tickInterval: TimeInterval = 0.5

    static func shouldRecover(now: Date, armedAt: Date, lastBufferAt: Date?) -> Bool {
        if let lastBufferAt {
            // A buffer from before this recording armed (warm idle audio)
            // still counts from the arm time, never earlier.
            let reference = max(lastBufferAt, armedAt)
            return now.timeIntervalSince(reference) > stallLimit
        }
        return now.timeIntervalSince(armedAt) > startupGrace
    }
}

/// YA-53: drops the first `remaining` samples written after a chime started,
/// so the start chime never lands in the WAV. Pure value logic; the owner
/// synchronizes.
struct ChimeTrimmer: Equatable {
    private(set) var remaining: Int = 0

    mutating func arm(samples: Int) {
        remaining = max(0, samples)
    }

    mutating func reset() {
        remaining = 0
    }

    /// How many leading samples of a chunk of `count` to drop.
    mutating func leadingSamplesToDrop(of count: Int) -> Int {
        let drop = min(max(0, count), remaining)
        remaining -= drop
        return drop
    }

    /// Chime length plus output latency and the room's echo tail, in 16 kHz
    /// samples.
    static func sampleCount(forChimeDuration duration: TimeInterval, sampleRate: Double = 16_000) -> Int {
        guard duration > 0 else { return 0 }
        return Int(((duration + latencyMargin) * sampleRate).rounded(.up))
    }

    static let latencyMargin: TimeInterval = 0.06
}

/// YA-22 / YA-04: whether the warm session must be rebuilt to honor the
/// requested device. `requestedUID == nil` means "follow the system default".
enum WarmSessionPlanner {
    static func needsRebuild(
        isRunning: Bool,
        builtForUID: String?,
        actualDeviceUID: String?,
        requestedUID: String?,
        systemDefaultUID: String?
    ) -> Bool {
        guard isRunning else { return true }
        guard builtForUID == requestedUID else { return true }
        if requestedUID == nil, let systemDefaultUID, let actualDeviceUID {
            return systemDefaultUID != actualDeviceUID
        }
        return false
    }
}

/// YA-55: multichannel inputs are averaged to mono before conversion instead
/// of keeping channel 1 only.
enum AudioDownmix {
    /// Returns a mono Float32 buffer with the per-frame average of every
    /// channel, or nil when the buffer is already mono or the sample format is
    /// not Float32, Int16 or Int32 (the converter then handles it unchanged).
    static func monoAverage(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 1,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let out = mono.floatChannelData?[0] else {
            return nil
        }

        let interleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channels)

        func sample(_ channel: Int, _ frame: Int, _ read: (Int, Int) -> Float) -> Float {
            interleaved ? read(0, frame * channels + channel) : read(channel, frame)
        }

        let read: (Int, Int) -> Float
        if let data = buffer.floatChannelData {
            read = { data[$0][$1] }
        } else if let data = buffer.int16ChannelData {
            read = { Float(data[$0][$1]) / 32768 }
        } else if let data = buffer.int32ChannelData {
            read = { Float(data[$0][$1]) / 2_147_483_648 }
        } else {
            return nil
        }

        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sample(channel, frame, read)
            }
            out[frame] = sum * scale
        }
        mono.frameLength = AVAudioFrameCount(frames)
        return mono
    }
}

/// YA-04: what RecordingController needs from a warm capture session. The
/// real one wraps an AVCaptureSession; self-tests inject a fake factory so the
/// concurrency of warm-session work is testable without a microphone.
protocol WarmCaptureSessionHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// UID of the device actually opened (may differ from the requested one
    /// when it fell back to the system default).
    var deviceUID: String? { get }
    /// Removes observers and stops capture. Called off the main thread.
    func stop()
}

/// YA-22: watches the system default input device through CoreAudio and calls
/// `onChange` on a background queue. Removed on deinit or `invalidate()`.
final class DefaultInputDeviceObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.yappyapp.YappYapp.default-input")
    private var block: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @Sendable () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        if status == noErr {
            block = listener
        }
    }

    func invalidate() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        self.block = nil
    }

    deinit {
        invalidate()
    }
}
