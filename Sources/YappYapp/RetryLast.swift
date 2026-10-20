import Foundation
import SwiftUI

// COMMANDS (missing feature 2, retry-last): the last recording stays in
// memory so it can be transcribed again with the current engine and
// settings. It never goes to disk on its own: a retry writes it to a private
// temp WAV that follows the normal temp-file lifecycle (tracked while in
// flight, deleted after, swept at launch). A new dictation and quitting both
// clear it.

struct LastRecording: Equatable, Sendable {
    let id: UUID
    let wav: Data
    let signalProfile: AudioSignalProfile?
    /// The transcription failed and FailedDictationStore holds the same
    /// audio on disk, so a retry should go through that store.
    var failed: Bool
}

@MainActor
final class LastRecordingMemory {
    /// A long dictation at the recorder's rate stays far below this; the cap
    /// only stops a runaway file from living in memory.
    static let maximumBytes = 96 * 1024 * 1024

    private(set) var recording: LastRecording?

    var hasRecording: Bool { recording != nil }

    /// Reads the WAV before it is normalized or deleted. Returns false when
    /// the file is missing or too large to keep.
    @discardableResult
    func remember(contentsOf url: URL, signalProfile: AudioSignalProfile?) -> Bool {
        recording = nil
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        recording = LastRecording(id: UUID(), wav: data, signalProfile: signalProfile, failed: false)
        return true
    }

    func markFailed() {
        recording?.failed = true
    }

    func markRecovered() {
        recording?.failed = false
    }

    func clear() {
        recording = nil
    }

    /// Writes the kept audio to a fresh private temp WAV for one retry. The
    /// caller owns the file from here on.
    func materialize(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL? {
        guard let recording else { return nil }
        let url = directory.appendingPathComponent("\(FailedDictationStore.filePrefix)\(UUID().uuidString).wav")
        try PrivateFile.write(recording.wav, to: url)
        return url
    }
}

enum RetryLastPlan: Equatable {
    /// Run FailedDictationStore's kept file (YA-05).
    case retryFailed
    /// Write the in-memory audio to a temp WAV and transcribe it again.
    case retranscribe
    case busyRecording
    case busyTranscribing
    case busyPasting
    case nothingYet
}

enum RetryLastPlanner {
    static func plan(
        phase: CapturePhase,
        isProcessing: Bool,
        pasteInFlight: Bool,
        memory: LastRecording?,
        hasFailedDictation: Bool
    ) -> RetryLastPlan {
        if phase == .recording { return .busyRecording }
        if phase == .transcribing || isProcessing { return .busyTranscribing }
        if pasteInFlight { return .busyPasting }
        if let memory {
            return memory.failed && hasFailedDictation ? .retryFailed : .retranscribe
        }
        return hasFailedDictation ? .retryFailed : .nothingYet
    }
}

enum RetryLastPresenter {
    static var menuTitle: String { L10n.tr("Retry Last Dictation") }
    static var buttonTitle: String { L10n.tr("RETRY") }

    static func statusText(for plan: RetryLastPlan) -> String? {
        switch plan {
        case .retryFailed, .retranscribe:
            return nil
        case .busyRecording:
            return L10n.tr("Finish this dictation first.")
        case .busyTranscribing:
            return L10n.tr("Still transcribing. Try again in a moment.")
        case .busyPasting:
            return L10n.tr("Still pasting the last dictation. One moment.")
        case .nothingYet:
            return L10n.tr("Nothing to retry yet. Dictate something first.")
        }
    }

    static var couldNotPrepare: String { L10n.tr("That recording can't be retried. Dictate it again.") }

    /// The HUD and the MIC tab offer RETRY on a failed transcription whose
    /// audio was kept.
    static func offersRetry(phase: CapturePhase, retryAvailable: Bool) -> Bool {
        guard retryAvailable, case .error = phase else { return false }
        return true
    }
}

extension HUDPresenter {
    /// COMMANDS: the HUD also takes clicks while it shows RETRY.
    static func acceptsMouse(_ phase: CapturePhase, retryAvailable: Bool) -> Bool {
        acceptsMouse(phase) || RetryLastPresenter.offersRetry(phase: phase, retryAvailable: retryAvailable)
    }
}

/// COMMANDS: the MIC tab's RETRY after a failed transcription. Brutal
/// chip: flat blue fill, 2pt frame, hard offset shadow.
struct RetryFailedButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(RetryLastPresenter.buttonTitle)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.8)
                .foregroundStyle(Brutal.contentOnBlue)
                .padding(.horizontal, 12)
                .frame(minHeight: 26)
                .background(Brutal.blue)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: L10n.tr("Retry"),
            hint: L10n.tr("Transcribes the failed dictation again"),
            hitExpansion: 9
        )
    }
}
