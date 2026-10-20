import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

// FILE-TRANSCRIPTION (missing feature 14): transcribe an audio or video file
// dropped on the FILES or MIC tab or picked from the menu. The file is converted to a
// 16 kHz mono WAV in a private temp folder, cut into ~60 s parts at quiet
// points, run through the current engine part by part, and deleted. The text
// lands only in this session's FILES results, where COPY and SAVE take it.
// FILES is separate from MIC: a file transcript never enters the dictation
// history, PASTE LAST, RETRY, undo, stats, the pet or the indicator, and it
// never touches the clipboard on its own.

enum FileTranscriptionInput {
    static let supportedExtensions: Set<String> = [
        "wav", "wave", "m4a", "mp3", "aif", "aiff", "aifc", "caf", "mp4", "mov"
    ]

    static var supportedLabel: String { L10n.tr("WAV, M4A, MP3, AIFF, CAF, MP4 or MOV") }

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static var contentTypes: [UTType] {
        var types: [UTType] = [.wav, .mpeg4Audio, .mp3, .aiff, .mpeg4Movie, .quickTimeMovie]
        if let caf = UTType(filenameExtension: "caf") {
            types.append(caf)
        }
        return types
    }
}

enum FileTranscriptionError: LocalizedError, Equatable {
    case unsupported
    case noAudioTrack
    case unreadable
    case tooLong(maxHours: Int)
    case tooShort
    case noSpeech
    case partFailed(part: Int, total: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n.tr("This file type is not supported. Use %@.", FileTranscriptionInput.supportedLabel)
        case .noAudioTrack:
            L10n.tr("This file has no audio track.")
        case .unreadable:
            L10n.tr("macOS could not read the audio in this file.")
        case .tooLong(let hours):
            L10n.tr("This file is longer than %@ hours. Split it and try again.", "\(hours)")
        case .tooShort:
            L10n.tr("This file is too short to transcribe.")
        case .noSpeech:
            L10n.tr("No speech found in this file.")
        case .partFailed(let part, let total, let reason):
            total > 1 ? L10n.tr("Part %@ of %@ failed. %@", "\(part)", "\(total)", reason) : reason
        }
    }
}

enum FileTranscriptionStage: Equatable, Sendable {
    case converting(Double)
    case transcribing(done: Int, total: Int)
}

enum FileTranscriptionStatus: Equatable {
    case running(fileName: String, stage: FileTranscriptionStage)
    case finished(fileName: String, words: Int)
    case failed(fileName: String, message: String)
    case canceled(fileName: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var fileName: String {
        switch self {
        case .running(let name, _), .finished(let name, _), .failed(let name, _), .canceled(let name):
            name
        }
    }
}

enum FileTranscriptionPresenter {
    /// Where a dropped or picked file sends the window: its own tab.
    static let destinationTab: BrutalTab = .files

    /// Converting is the quick part; it gets the first 15% of the bar.
    static let conversionShare = 0.15

    static func headline(for status: FileTranscriptionStatus) -> String {
        switch status {
        case .running: L10n.tr("TRANSCRIBING FILE")
        case .finished: L10n.tr("FILE TRANSCRIBED")
        case .failed: L10n.tr("FILE NOT TRANSCRIBED")
        case .canceled: L10n.tr("FILE CANCELED")
        }
    }

    static func detail(for status: FileTranscriptionStatus) -> String {
        switch status {
        case .running(_, .converting(let fraction)):
            L10n.tr("PREPARING %@%%", "\(percent(fraction))")
        case .running(_, .transcribing(let done, let total)):
            total > 1 ? L10n.tr("PART %@ OF %@", "\(min(done + 1, total))", "\(total)") : L10n.tr("READING THE AUDIO")
        case .finished(_, let words):
            L10n.plural("%lld WORDS · READY TO COPY OR SAVE", words)
        case .failed(_, let message):
            message
        case .canceled:
            L10n.tr("NO TRANSCRIPT KEPT")
        }
    }

    /// 0...1 for the progress bar, nil when no bar should show.
    static func progress(for status: FileTranscriptionStatus) -> Double? {
        switch status {
        case .running(_, .converting(let fraction)):
            conversionShare * clamp(fraction)
        case .running(_, .transcribing(let done, let total)):
            conversionShare + (1 - conversionShare) * clamp(Double(done) / Double(max(total, 1)))
        default:
            nil
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((clamp(fraction) * 100).rounded(.down))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Picks part boundaries at the quietest moment shortly before each ~60 s
/// mark, so a cut rarely lands mid-word. Pure: energy comes from a closure.
enum FileTranscriptionChunker {
    static let sampleRate = 16_000
    static let targetSamples = 60 * sampleRate
    static let searchSamples = 8 * sampleRate
    static let windowSamples = 1_600  // 100 ms
    /// A last part shorter than this rides along with the one before it.
    static let minimumTailSamples = 3 * sampleRate

    static func ranges(
        totalSamples: Int,
        target: Int = targetSamples,
        search: Int = searchSamples,
        window: Int = windowSamples,
        minimumTail: Int = minimumTailSamples,
        energy: (Range<Int>) -> Double
    ) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        let step = max(1, window / 2)
        var result: [Range<Int>] = []
        var start = 0
        while totalSamples - start > target + minimumTail {
            let idealEnd = start + target
            var bestEnd = idealEnd
            var bestEnergy = Double.infinity
            var probe = max(start + window, idealEnd - search)
            while probe + window <= idealEnd {
                let value = energy(probe..<(probe + window))
                if value < bestEnergy {
                    bestEnergy = value
                    bestEnd = probe + window / 2
                }
                probe += step
            }
            result.append(start..<bestEnd)
            start = bestEnd
        }
        result.append(start..<totalSamples)
        return result
    }
}

/// Decodes any audio or video file AVFoundation can read into a 16 kHz mono
/// 16-bit WAV. Every channel and audio track is mixed down.
enum AudioFileConverter {
    static let maximumHours = 4

    static let outputSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    /// Returns the number of samples written. Throws CancellationError when
    /// the surrounding task is canceled.
    static func convert(
        source: URL,
        destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        let duration: Double
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
        } catch {
            throw FileTranscriptionError.unreadable
        }
        guard !tracks.isEmpty else { throw FileTranscriptionError.noAudioTrack }
        if duration.isFinite, duration > Double(maximumHours * 3600) {
            throw FileTranscriptionError.tooLong(maxHours: maximumHours)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FileTranscriptionError.unreadable
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileTranscriptionError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw FileTranscriptionError.unreadable }

        let writer = try WAVFileWriter(url: destination, sampleRate: 16_000, channels: 1)
        try? PrivateFile.hardenFileIfPresent(at: destination)
        defer { writer.finalize() }

        var samples = 0
        let maximumSamples = maximumHours * 3600 * 16_000
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == noErr else { continue }
            try writer.append(pcmBytes: data)
            samples += length / MemoryLayout<Int16>.size
            if samples > maximumSamples {
                reader.cancelReading()
                throw FileTranscriptionError.tooLong(maxHours: maximumHours)
            }
            if duration.isFinite, duration > 0 {
                progress(min(1, Double(samples) / 16_000 / duration))
            }
        }
        if reader.status == .failed {
            throw FileTranscriptionError.unreadable
        }
        try Task.checkCancellation()
        return samples
    }
}

/// How a part reaches the engine. The app wires these to the same transcribe
/// path a dictation uses (glossary and filler removal included) and to the
/// optional local cleanup.
struct FileTranscriptionEngine: Sendable {
    var transcribePart: @Sendable @MainActor (URL, Bool) async throws -> String
    var cleanup: @Sendable (String) async -> String
    var finish: @Sendable @MainActor () async -> Void
}

enum FileTranscriptionPipeline {
    static let workDirectoryPrefix = TempFileSweeper.prefix + "file-"

    /// Converts, splits and transcribes `source` inside `workDirectory`, which
    /// the caller creates and deletes. Parts are deleted as soon as they are
    /// done. Returns the joined transcript.
    static func run(
        source: URL,
        workDirectory: URL,
        engine: FileTranscriptionEngine,
        progress: @escaping @Sendable (FileTranscriptionStage) -> Void
    ) async throws -> String {
        let converted = workDirectory.appendingPathComponent("audio.wav")
        progress(.converting(0))
        let total = try await AudioFileConverter.convert(source: source, destination: converted) { fraction in
            progress(.converting(fraction))
        }
        guard total >= FileTranscriptionChunker.sampleRate / 2 else {
            throw FileTranscriptionError.tooShort
        }

        let data = try Data(contentsOf: converted, options: .alwaysMapped)
        let headerSize = 44
        let available = (data.count - headerSize) / MemoryLayout<Int16>.size
        let sampleCount = min(total, max(0, available))
        let ranges = FileTranscriptionChunker.ranges(totalSamples: sampleCount) { range in
            meanMagnitude(in: data, headerSize: headerSize, range: range)
        }

        var parts: [String] = []
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            progress(.transcribing(done: index, total: ranges.count))

            let partURL = workDirectory.appendingPathComponent("part-\(index).wav")
            defer { try? FileManager.default.removeItem(at: partURL) }
            try writePart(of: data, headerSize: headerSize, range: range, to: partURL)

            // Same gates as a dictation: skip silence, lift quiet speech.
            let profile = AudioNormalizer.signalProfile(url: partURL)
            guard profile?.hasMeaningfulSignal == true else { continue }
            let nearSilence = WhisperOutputGuard.isNearSilence(profile)
            AudioNormalizer.normalize(url: partURL)

            let text: String
            do {
                text = try await engine.transcribePart(partURL, nearSilence)
            } catch WhisperError.noSpeech, WhisperError.emptyTranscript {
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw FileTranscriptionError.partFailed(
                    part: index + 1,
                    total: ranges.count,
                    reason: error.localizedDescription
                )
            }
            try Task.checkCancellation()
            let cleaned = await engine.cleanup(text)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        progress(.transcribing(done: ranges.count, total: ranges.count))

        let transcript = parts.joined(separator: " ")
        guard !transcript.isEmpty else { throw FileTranscriptionError.noSpeech }
        return transcript
    }

    static func meanMagnitude(in data: Data, headerSize: Int, range: Range<Int>) -> Double {
        data.withUnsafeBytes { raw -> Double in
            guard range.count > 0 else { return 0 }
            let start = headerSize + range.lowerBound * 2
            let end = headerSize + range.upperBound * 2
            guard start >= 0, end <= raw.count else { return 0 }
            var sum = 0.0
            var offset = start
            while offset < end {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                sum += abs(Double(value))
                offset += 2
            }
            return sum / Double(range.count)
        }
    }

    static func writePart(of data: Data, headerSize: Int, range: Range<Int>, to url: URL) throws {
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
        try? PrivateFile.hardenFileIfPresent(at: url)
        defer { writer.finalize() }
        let start = headerSize + range.lowerBound * 2
        let end = headerSize + range.upperBound * 2
        try writer.append(pcmBytes: data.subdata(in: start..<end))
    }
}

/// Optional local cleanup for one transcribed part, mirroring what a
/// dictation gets: the cleanup pass when Setup's mode runs the model, then the
/// glossary has the last word. A file is cut into ~60 s parts, so a layout
/// mode (Email, List, Notes) would lay out each part on its own: every mode
/// that runs the model tidies a file part as Clean.
enum FileTranscriptionCleanup {
    static func mode(for config: AppConfig) -> CleanupMode {
        config.cleanup.usesModel ? .clean : .verbatim
    }

    static func apply(
        _ text: String,
        config: AppConfig,
        glossary: Glossary,
        environment: CleanupEnvironment = .live
    ) async -> String {
        let mode = mode(for: config)
        guard mode.usesModel, LLMCleaner.isWorthCleaning(text) else { return text }
        let protectedTerms = LLMCleaner.protectedTerms(from: glossary)
        let llamaBinaryPath = config.llamaBinaryPath
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: LLMCleaner.cleanup(
                    text: text,
                    mode: mode,
                    protectedTerms: protectedTerms,
                    llamaBinaryPath: llamaBinaryPath,
                    environment: environment
                ))
            }
        }
        guard case .cleaned = result.outcome, result.text != text else { return text }
        return glossary.applyingCorrections(to: result.text)
    }
}

/// Owns the one file job that may run at a time. Main-thread only.
@MainActor
final class FileTranscriptionCoordinator {
    enum StartResult: Equatable {
        case started
        case busy
        case unsupported
    }

    private let state: YappYappState
    private let makeEngine: () -> FileTranscriptionEngine
    private let temporaryRoot: URL
    private var job: Task<Void, Never>?
    private var jobID = 0
    private var workDirectory: URL?

    init(
        state: YappYappState,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        makeEngine: @escaping () -> FileTranscriptionEngine
    ) {
        self.state = state
        self.temporaryRoot = temporaryRoot
        self.makeEngine = makeEngine
    }

    var isRunning: Bool { job != nil }

    /// Starts a job for `url`. One file at a time; a dictation can still run.
    @discardableResult
    func start(url: URL) -> StartResult {
        guard job == nil else { return .busy }
        let fileName = url.lastPathComponent
        guard FileTranscriptionInput.accepts(url) else {
            state.fileTranscription = .failed(
                fileName: fileName,
                message: FileTranscriptionError.unsupported.errorDescription ?? ""
            )
            return .unsupported
        }

        let directory = temporaryRoot.appendingPathComponent(
            FileTranscriptionPipeline.workDirectoryPrefix + UUID().uuidString
        )
        do {
            try PrivateFile.ensureDirectory(at: directory)
        } catch {
            state.fileTranscription = .failed(fileName: fileName, message: error.localizedDescription)
            return .unsupported
        }

        jobID += 1
        let id = jobID
        workDirectory = directory
        state.fileTranscription = .running(fileName: fileName, stage: .converting(0))
        let engine = makeEngine()

        // Security-scoped access matters only for sandboxed builds; harmless here.
        let scoped = url.startAccessingSecurityScopedResource()
        // The coordinator lives as long as the app, so strong captures are fine.
        job = Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: directory)
            }
            let outcome: Result<String, Error>
            do {
                let text = try await FileTranscriptionPipeline.run(
                    source: url,
                    workDirectory: directory,
                    engine: engine,
                    progress: { stage in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self.report(stage, id: id, fileName: fileName) }
                        }
                    }
                )
                outcome = .success(text)
            } catch {
                outcome = .failure(error)
            }
            await engine.finish()
            self.complete(outcome, id: id, fileName: fileName)
        }
        return .started
    }

    /// Stops the job now. The text of a part still decoding is thrown away.
    func cancel() {
        guard let job, case .running(let fileName, _) = state.fileTranscription else { return }
        job.cancel()
        jobID += 1
        self.job = nil
        state.fileTranscription = .canceled(fileName: fileName)
    }

    /// Clears a finished, failed or canceled card.
    func dismiss() {
        guard state.fileTranscription?.isRunning == false else { return }
        state.fileTranscription = nil
    }

    /// Quit: cancel and delete the temp folder right away.
    func shutdown() {
        job?.cancel()
        job = nil
        jobID += 1
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
    }

    private func report(_ stage: FileTranscriptionStage, id: Int, fileName: String) {
        guard id == jobID else { return }
        state.fileTranscription = .running(fileName: fileName, stage: stage)
    }

    private func complete(_ outcome: Result<String, Error>, id: Int, fileName: String) {
        guard id == jobID else { return }
        job = nil
        workDirectory = nil
        switch outcome {
        case .success(let text):
            // FILES only: no MIC history, no lastTranscript, no clipboard.
            // COPY on the result row is the one way it reaches the clipboard.
            state.recordFileResult(fileName: fileName, text: text)
            let words = text.split(whereSeparator: \.isWhitespace).count
            state.fileTranscription = .finished(fileName: fileName, words: words)
        case .failure(let error) where error is CancellationError:
            state.fileTranscription = .canceled(fileName: fileName)
        case .failure(let error):
            state.fileTranscription = .failed(fileName: fileName, message: error.localizedDescription)
        }
    }
}

/// SAVE on a FILES result: a plain-text file next to wherever the user
/// picks, named after the source file.
@MainActor
enum FileTranscriptSaver {
    static func suggestedName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? L10n.tr("Transcript") : base) + ".txt"
    }

    /// Returns the saved file, or nil when the user canceled the panel.
    static func save(_ result: FileTranscriptResult) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Save transcript")
        panel.prompt = L10n.tr("Save")
        panel.nameFieldStringValue = suggestedName(for: result.fileName)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try Data(result.text.utf8).write(to: url, options: .atomic)
        return url
    }
}

/// The open panel behind "Transcribe Audio File...".
@MainActor
enum FileTranscriptionPicker {
    static func choose(_ completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTranscriptionInput.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L10n.tr("Transcribe")
        panel.message = L10n.tr("Pick an audio or video file. The transcript shows up in FILES, ready to copy or save.")
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }
}
