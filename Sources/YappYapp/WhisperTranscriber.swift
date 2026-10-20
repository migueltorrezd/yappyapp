import Foundation

/// Reference box so a background pipe-drain can hand its result back to the
/// synchronous transcribe frame across a DispatchQueue boundary.
private final class PipeDrainBox: @unchecked Sendable {
    var data = Data()
}

/// YA-05: set by the CLI watchdog when it stops a run that ran too long.
private final class WatchdogFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

enum WhisperError: LocalizedError {
    case binaryMissing(String)
    // HELPER-BINARY-POLICY (YA-63): present, but not safe to run.
    case binaryRefused(String, String)
    case modelMissing(String)
    case modelUnavailable(String)
    case processFailed(Int32, String)
    case serverFailed(String)
    case emptyTranscript
    /// YA-48: the model only produced a silence hallucination or its prompt.
    case noSpeech
    /// YA-05: the engine ran past a budget scaled to the audio length.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            L10n.tr("Missing whisper-cli at %@.", path)
        case .binaryRefused(let path, let reason):
            L10n.tr("YappYapp will not run %@: %@.", path, reason)
        case .modelMissing(let path):
            L10n.tr("Missing Whisper model at %@.", path)
        case .modelUnavailable(let message):
            message
        case .processFailed(let code, let output):
            L10n.tr("whisper-cli failed with exit code %@. %@", "\(code)", output)
        case .serverFailed(let message):
            L10n.tr("Local Whisper server request failed. %@", message)
        case .emptyTranscript:
            L10n.tr("Whisper heard no words. Try again a little louder.")
        case .noSpeech:
            L10n.tr("No speech heard. Nothing was typed.")
        case .timedOut:
            L10n.tr("Transcribing took too long.")
        }
    }
}

final class WhisperTranscriber: Sendable {
    func readiness(for config: AppConfig) -> (binary: Bool, model: Bool) {
        let modelPath = config.modelPath.expandingTildeInPath
        return (
            // HELPER-BINARY-POLICY (YA-63): only a binary we would actually run counts.
            HelperBinaryPolicy.validate(config.whisperBinaryPath).allowedPath != nil,
            FileManager.default.fileExists(atPath: modelPath)
        )
    }

    /// `timeout` scales with the audio length (YA-05); the default keeps the
    /// old fixed budget for callers that do not know the duration.
    func transcribe(
        audioURL: URL,
        config: AppConfig,
        glossary: Glossary,
        timeout: TimeInterval = TranscriptionTimeouts.cliMinimum
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let modelPath = config.modelPath.expandingTildeInPath

            // HELPER-BINARY-POLICY (YA-63): bundle or validated absolute path only.
            guard let binaryPath = HelperBinaryPolicy.launchablePath(config.whisperBinaryPath) else {
                throw WhisperError.binaryProblem(for: config.whisperBinaryPath)
            }

            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw WhisperError.modelMissing(modelPath)
            }

            let outputBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("yappyapp-transcript-\(UUID().uuidString)")

            // YA-49: the prompt travels in a private file, never in argv.
            let promptFile = try WhisperPromptFile.write(
                WhisperServerController.promptText(config: config, glossary: glossary)
            )
            defer { WhisperPromptFile.remove(promptFile) }
            let supportsPromptFile = promptFile != nil
                && WhisperPromptFile.binarySupportsPromptFile(atPath: binaryPath)

            let arguments = Self.cliArguments(
                modelPath: modelPath,
                audioPath: audioURL.path,
                outputBasePath: outputBase.path,
                config: config,
                promptFile: promptFile,
                binarySupportsPromptFile: supportsPromptFile
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()

            // FIX pipeDrain: drain the shared stdout/stderr pipe on a background
            // queue concurrently with waitUntilExit(). Reading only after the
            // child exits deadlocks it once output exceeds the ~64KB pipe buffer
            // (long dictation, verbose backend error dump): the child blocks on a
            // full pipe while we block in waitUntilExit(), and the 75s watchdog
            // then SIGTERMs an otherwise-successful transcription.
            let readHandle = outputPipe.fileHandleForReading
            let outputBox = PipeDrainBox()
            let drainQueue = DispatchQueue(label: "com.yappyapp.whisper.output")
            drainQueue.async {
                outputBox.data = readHandle.readDataToEndOfFile()
            }

            // A wedged whisper-cli must not hold the app in .transcribing forever.
            let watchdogFired = WatchdogFlag()
            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    // YA-05: remember why it stopped, so the user sees an
                    // honest timeout instead of a raw exit code.
                    watchdogFired.set()
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: watchdog)

            process.waitUntilExit()
            watchdog.cancel()

            // Barrier: wait for the drain to reach EOF (child's write ends are
            // now closed) so the full output is captured.
            drainQueue.sync {}
            let outputData = outputBox.data
            let processOutput = String(data: outputData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("txt"))

                if watchdogFired.isSet {
                    throw WhisperError.timedOut
                }

                // whisper-cli dumps pages of backend logs; keep only the part
                // a human needs to see.
                let relevantLine = processOutput
                    .components(separatedBy: .newlines)
                    .last { $0.localizedCaseInsensitiveContains("error") }
                    ?? String(processOutput.suffix(200))

                throw WhisperError.processFailed(process.terminationStatus, relevantLine)
            }

            let transcriptURL = outputBase.appendingPathExtension("txt")
            let rawTranscript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? processOutput
            try? FileManager.default.removeItem(at: transcriptURL)

            let normalized = rawTranscript
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalized.isEmpty else {
                throw WhisperError.emptyTranscript
            }

            return glossary.applyingCorrections(to: normalized)
        }.value
    }

    /// whisper-cli arguments. The prompt text itself never appears here;
    /// only the path of its private file, and only when the binary reads it.
    static func cliArguments(
        modelPath: String,
        audioPath: String,
        outputBasePath: String,
        config: AppConfig,
        promptFile: URL?,
        binarySupportsPromptFile: Bool
    ) -> [String] {
        var arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "-otxt",
            "-of", outputBasePath,
            "-nt",
            "-np",
            "-sns"
        ]

        if !config.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["-l", config.language])
        }

        if config.whisperTranslates {
            arguments.append("-tr")
        }

        if config.quietVoiceBoost {
            // Keep low-energy (whispered) segments instead of dropping them
            // as silence, and use beam search for harder audio.
            arguments.append(contentsOf: ["-nth", "0.95", "-bs", "5"])
        }

        arguments.append(contentsOf: WhisperPromptFile.arguments(
            promptFile: promptFile,
            binarySupportsPromptFile: binarySupportsPromptFile
        ))
        return arguments
    }
}
