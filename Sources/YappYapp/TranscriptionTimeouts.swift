import AVFoundation
import Foundation

/// YA-05: every transcription time limit scales with how much audio there is.
/// A fixed 60s request timeout and 90s watchdog dropped long Whisper
/// dictations, especially with beam search (Quiet Voice Boost) on.
enum TranscriptionTimeouts {
    /// Seconds of compute allowed per second of audio. Beam search decodes
    /// five candidates, so it gets a far longer leash. Generous on purpose:
    /// a slow Intel or a busy Mac must finish, not time out.
    static let greedySecondsPerAudioSecond: Double = 1.0
    static let beamSecondsPerAudioSecond: Double = 3.0

    static let serverBase: TimeInterval = 30
    static let serverMinimum: TimeInterval = 60
    static let serverMaximum: TimeInterval = 3_600

    /// The cold CLI also loads the model from disk on every run.
    static let cliModelLoadAllowance: TimeInterval = 45
    static let cliMinimum: TimeInterval = 75

    /// Extra time past the slowest engine path before the app gives up.
    static let watchdogSlack: TimeInterval = 15
    static let whisperWatchdogMinimum: TimeInterval = 90
    static let parakeetWatchdogMinimum: TimeInterval = 90
    /// YA-01: nothing downloads during a dictation any more. A cold load from
    /// the verified cache still compiles CoreML, so it gets a modest margin.
    static let parakeetFirstLoadWatchdog: TimeInterval = 180

    static func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func serverRequestTimeout(audioSeconds: TimeInterval, beamSearch: Bool) -> TimeInterval {
        let perSecond = beamSearch ? beamSecondsPerAudioSecond : greedySecondsPerAudioSecond
        let scaled = serverBase + max(0, audioSeconds) * perSecond
        return min(serverMaximum, max(serverMinimum, scaled))
    }

    static func cliTimeout(audioSeconds: TimeInterval, beamSearch: Bool) -> TimeInterval {
        let perSecond = beamSearch ? beamSecondsPerAudioSecond : greedySecondsPerAudioSecond
        let scaled = cliModelLoadAllowance + serverBase + max(0, audioSeconds) * perSecond
        return min(serverMaximum, max(cliMinimum, scaled))
    }

    /// The app-level watchdog covers the slowest path a dictation can take.
    /// The CLI only runs after the server could not be reached, which fails
    /// fast, so the two budgets do not add up.
    static func whisperWatchdog(audioSeconds: TimeInterval, beamSearch: Bool) -> TimeInterval {
        let slowest = max(
            serverRequestTimeout(audioSeconds: audioSeconds, beamSearch: beamSearch),
            cliTimeout(audioSeconds: audioSeconds, beamSearch: beamSearch)
        )
        return max(whisperWatchdogMinimum, slowest + watchdogSlack)
    }

    /// QWEN3-ASR: greedy like Whisper without beam search, on the server or
    /// the one-shot helper. Audio past `Qwen3ASRPrompt.chunkSeconds` runs as
    /// several requests, each with its own budget, so the whole recording
    /// gets the sum of its parts plus one model load.
    static func qwen3ASRWatchdog(audioSeconds: TimeInterval) -> TimeInterval {
        let parts = max(1, Int((max(0, audioSeconds) / Double(Qwen3ASRPrompt.chunkSeconds)).rounded(.up)))
        let perPart = min(audioSeconds, Double(Qwen3ASRPrompt.chunkSeconds))
        let slowestPart = max(
            serverRequestTimeout(audioSeconds: perPart, beamSearch: false),
            cliTimeout(audioSeconds: perPart, beamSearch: false)
        )
        return max(whisperWatchdogMinimum, Double(parts) * slowestPart + watchdogSlack)
    }

    static func parakeetWatchdog(audioSeconds: TimeInterval, modelLoaded: Bool) -> TimeInterval {
        // Parakeet runs far faster than real time; this only guards a hang.
        let warm = max(parakeetWatchdogMinimum, 30 + max(0, audioSeconds) * 0.5)
        guard modelLoaded else {
            return max(parakeetFirstLoadWatchdog, warm + parakeetFirstLoadWatchdog - parakeetWatchdogMinimum)
        }
        return warm
    }
}

/// YA-05: only a server that could not be reached, or that refused the
/// request outright, hands the dictation to the cold CLI. A timeout means the
/// server is still busy with this audio; starting a second full model in
/// parallel would only make both slower.
enum WhisperServerFailure {
    static func shouldFallBackToCLI(_ error: Error) -> Bool {
        if let controllerError = error as? WhisperServerControllerError {
            return controllerError == .notRunning
        }
        // The server answered at once with an HTTP error: it is not busy
        // with this audio, so the CLI can try without doubling the work.
        if let whisperError = error as? WhisperError, case .serverFailed = whisperError {
            return true
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorBadServerResponse:
            return true
        default:
            return false
        }
    }

    static func isTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}

enum WhisperServerControllerError: Error, Equatable {
    /// No warm server endpoint was ready when the request was built.
    case notRunning
}
