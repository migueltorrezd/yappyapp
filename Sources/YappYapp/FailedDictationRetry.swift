import Foundation

/// YA-05: a recording whose transcription failed, kept so the user can retry
/// instead of losing what they said. `signalProfile` is the level measured
/// before normalization, which the silence guard (YA-48) needs on a retry.
struct RetryableDictation: Equatable, Sendable {
    let audioURL: URL
    let signalProfile: AudioSignalProfile?
}

/// YA-05: holds at most one failed recording. The audio moves into a
/// private (owner-only) file; a newer failure replaces it, a retry takes it,
/// and quitting deletes it. Main thread only.
final class FailedDictationStore {
    static let filePrefix = "yappyapp-retry-"

    private let directory: URL
    private(set) var pending: RetryableDictation?

    init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    var hasPending: Bool {
        pending != nil
    }

    /// Moves the recording out of the recorder's hands. Returns false when
    /// the file could not be kept, so the caller can say so honestly.
    @discardableResult
    func keep(audioURL: URL, signalProfile: AudioSignalProfile?) -> Bool {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return false }

        // A retry that fails again hands back the same kept file.
        if pending?.audioURL == audioURL {
            pending = RetryableDictation(audioURL: audioURL, signalProfile: signalProfile)
            return true
        }

        let destination = directory.appendingPathComponent("\(Self.filePrefix)\(UUID().uuidString).wav")
        do {
            try FileManager.default.moveItem(at: audioURL, to: destination)
            try PrivateFile.hardenFileIfPresent(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return false
        }

        discard()
        pending = RetryableDictation(audioURL: destination, signalProfile: signalProfile)
        return true
    }

    /// Hands the kept recording to a retry. The file stays on disk until the
    /// retry delivers a transcript (`finished`) or fails again (`keep`).
    func take() -> RetryableDictation? {
        pending
    }

    /// The retry delivered its transcript: the audio is no longer needed.
    func finished(_ dictation: RetryableDictation) {
        guard pending?.audioURL == dictation.audioURL else {
            try? FileManager.default.removeItem(at: dictation.audioURL)
            return
        }
        discard()
    }

    func discard() {
        if let url = pending?.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        pending = nil
    }
}

/// YA-05: honest copy for a failed dictation. When the audio was kept, the
/// message says where to retry it.
enum DictationFailurePresenter {
    static var retryHint: String { L10n.tr("Your audio is kept. Press RETRY, or use Retry Last Dictation in the menu bar.") }
    static var retryMenuTitle: String { L10n.tr("Retry Last Dictation") }

    /// Silence and empty output have nothing worth retrying.
    static func keepsAudio(for error: Error) -> Bool {
        guard let whisperError = error as? WhisperError else { return true }
        switch whisperError {
        case .noSpeech, .emptyTranscript:
            return false
        default:
            return true
        }
    }

    static func message(for error: Error, audioKept: Bool) -> String {
        let base = error.localizedDescription
        return audioKept ? "\(base) \(retryHint)" : base
    }
}
