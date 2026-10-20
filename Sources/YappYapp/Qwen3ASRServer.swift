import Foundation

// QWEN3-ASR-WARM: the speech instance of the warm llama-server (see
// LlamaServerController.swift). It runs only while a Qwen3-ASR model is the
// selected speech model, both of its files are verified, "keep the model
// warm" is on and memory is not critical. Switching to another engine stops
// it; switching size replaces it. The recording travels base64-encoded in the
// body of a loopback request (an input_audio part), never in argv, and the
// server logs nothing. Not ready, another size loaded, or no server at all:
// the one-shot llama-mtmd-cli runs instead, like the cold whisper-cli.
//
// Measured on an M5 Pro (2026-10-18, 6 to 8 s clips): warm requests take
// about 0.15 s with 0.6B and 0.3 s with 1.7B; one-shot runs about 1.2 s and
// 1.5 s.

/// Pure rules, pinned by the self-tests and unit tests.
enum Qwen3ASRServerPolicy {
    /// The server to run, or nil when none should run.
    static func launch(
        config: AppConfig,
        runtimeBinary: String?,
        modelVerified: (Qwen3ASRVariant) -> Bool,
        memoryPressureCritical: Bool,
        launchable: (String) -> String?
    ) -> LlamaServerLaunch? {
        guard let variant = Qwen3ASRVariant.from(modelPath: config.modelPath),
              config.keepModelWarm, !memoryPressureCritical, modelVerified(variant),
              let server = LlamaServerPolicy.bundledServer(runtimeBinary: runtimeBinary, launchable: launchable) else {
            return nil
        }
        return LlamaServerLaunch(
            binary: server,
            model: Qwen3ASRModelStore.modelURL(variant).path,
            contextTokens: Qwen3ASRPrompt.contextTokens,
            projector: Qwen3ASRModelStore.projectorURL(variant).path
        )
    }

    /// The model card's chat: the context as the system turn, the audio alone
    /// as the user turn, and with a known language the assistant prefill that
    /// asks for the transcript only. Greedy, no translation.
    static func requestBody(wav: Data, context: String, prefill: String?, maxTokens: Int) -> Data {
        var messages: [[String: Any]] = [
            ["role": "system", "content": context],
            ["role": "user", "content": [
                ["type": "input_audio", "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]
            ]]
        ]
        if let prefill {
            messages.append(["role": "assistant", "content": prefill])
        }
        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0,
            "max_tokens": maxTokens,
            "cache_prompt": true,
            "stream": false
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Half a second of silence: compiles the audio encoder's kernels before
    /// the first dictation. The model answers "language None".
    static var warmUpBody: Data {
        requestBody(wav: silentWAV(seconds: 0.5), context: "", prefill: nil, maxTokens: 1)
    }

    /// A 16 kHz mono 16-bit WAV of silence.
    static func silentWAV(seconds: Double) -> Data {
        let samples = max(1, Int(seconds * 16_000))
        let dataBytes = UInt32(samples * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
        append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        return data
    }
}

extension LlamaServerController {
    /// The warm Qwen3-ASR speech model.
    static let speech = LlamaServerController(
        label: "speech",
        warmUpBody: Qwen3ASRServerPolicy.warmUpBody,
        warmUpTimeout: 60
    )
}

// MARK: - Transcribing

enum Qwen3ASRError: LocalizedError, Equatable {
    /// No bundled llama.cpp audio helper (a source build without it).
    case runtimeMissing
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            L10n.tr("This copy of YappYapp can't run Qwen3-ASR. Reinstall it from the latest DMG, or pick another model.")
        case .processFailed(let code):
            L10n.tr("Qwen3-ASR stopped with exit code %@. Try again.", "\(code)")
        }
    }
}

/// Transcribes one recording with a Qwen3-ASR model: the warm server first,
/// the one-shot llama-mtmd-cli when the server is not ready. Long recordings
/// are cut at quiet moments into parts the model's context holds.
struct Qwen3ASRTranscriber: Sendable {
    var server: @Sendable (Data, TimeInterval, String) -> LlamaServerReply = {
        LlamaServerController.speech.complete(body: $0, timeout: $1, model: $2)
    }
    var cliBinary: @Sendable (AppConfig) -> String? = { config in
        Qwen3ASRRuntime.bundledCLI(
            runtimeBinary: LLMCleaner.binaryPath(configured: config.llamaBinaryPath),
            launchable: { HelperBinaryPolicy.launchablePath($0) }
        )
    }
    /// Binary, arguments, stdin prompt, timeout.
    var runCLI: @Sendable (String, [String], String, TimeInterval) throws -> String = Qwen3ASRProcess.run

    /// Blocking parts run on a detached task; the returned text has the
    /// glossary applied and is empty only when the model heard no speech.
    func transcribe(
        audioURL: URL,
        variant: Qwen3ASRVariant,
        config: AppConfig,
        glossary: Glossary,
        audioSeconds: TimeInterval
    ) async throws -> String {
        let transcriber = self
        return try await Task.detached(priority: .userInitiated) {
            try transcriber.transcribeBlocking(
                audioURL: audioURL,
                variant: variant,
                config: config,
                glossary: glossary,
                audioSeconds: audioSeconds
            )
        }.value
    }

    func transcribeBlocking(
        audioURL: URL,
        variant: Qwen3ASRVariant,
        config: AppConfig,
        glossary: Glossary,
        audioSeconds: TimeInterval
    ) throws -> String {
        let parts = try Qwen3ASRAudioParts.split(audioURL, audioSeconds: audioSeconds)
        defer { parts.cleanUp() }

        var texts: [String] = []
        for part in parts.items {
            try Task.checkCancellation()
            let text = try transcribePart(
                part.url,
                seconds: part.seconds,
                variant: variant,
                config: config,
                context: Qwen3ASRPrompt.context(glossary: glossary)
            )
            if !text.isEmpty { texts.append(text) }
        }
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw WhisperError.noSpeech }
        return glossary.applyingCorrections(to: joined)
    }

    private func transcribePart(
        _ url: URL,
        seconds: TimeInterval,
        variant: Qwen3ASRVariant,
        config: AppConfig,
        context: String
    ) throws -> String {
        let maxTokens = Qwen3ASRPrompt.maxTokens(audioSeconds: seconds)
        let wav = try Data(contentsOf: url)
        let body = Qwen3ASRServerPolicy.requestBody(
            wav: wav,
            context: context,
            prefill: Qwen3ASRPrompt.assistantPrefill(language: config.language),
            maxTokens: maxTokens
        )
        let modelPath = Qwen3ASRModelStore.modelURL(variant).path
        switch server(body, TranscriptionTimeouts.serverRequestTimeout(audioSeconds: seconds, beamSearch: false), modelPath) {
        case .text(let reply):
            return Qwen3ASRPrompt.transcript(fromReply: reply)
        case .timedOut:
            // Busy with this very audio: a second full model would only be
            // slower. The controller already replaced the server.
            throw WhisperError.timedOut
        case .unavailable:
            break
        }

        guard let binary = cliBinary(config) else { throw Qwen3ASRError.runtimeMissing }
        let arguments = Qwen3ASRCLI.arguments(
            variant: variant,
            modelURL: Qwen3ASRModelStore.modelURL(variant),
            projectorURL: Qwen3ASRModelStore.projectorURL(variant),
            audioPath: url.path,
            maxTokens: maxTokens
        )
        // WORDS-AS-HINTS: the same context and language prefill as the warm
        // server, over stdin.
        let prompt = Qwen3ASRCLI.stdinPrompt(context: context, prefill: Qwen3ASRPrompt.assistantPrefill(language: config.language))
        let output = try runCLI(binary, arguments, prompt, TranscriptionTimeouts.cliTimeout(audioSeconds: seconds, beamSearch: false))
        return Qwen3ASRPrompt.transcript(fromReply: output)
    }
}

/// Runs llama-mtmd-cli once. Stdout is the reply; stderr (its logs) goes to
/// /dev/null, so nothing it prints reaches a file.
enum Qwen3ASRProcess {
    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    static func run(binary: String, arguments: [String], input: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        let stdin = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()

        // The prompt (glossary context) goes in over stdin, never argv. A
        // helper that dies first must not take the app down with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain while it runs, so a long reply never fills the pipe buffer.
        let box = Box()
        let drain = DispatchQueue(label: "com.yappyapp.qwen3asr.output")
        let handle = pipe.fileHandleForReading
        drain.async { box.data = handle.readDataToEndOfFile() }

        let fired = Flag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                fired.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        drain.sync {}

        if fired.isSet { throw WhisperError.timedOut }
        guard process.terminationStatus == 0 else {
            throw Qwen3ASRError.processFailed(process.terminationStatus)
        }
        return String(decoding: box.data, as: UTF8.self)
    }
}

/// A recording longer than `Qwen3ASRPrompt.chunkSeconds` is cut at quiet
/// moments (the same chunker FILES uses) into private temporary WAVs.
struct Qwen3ASRAudioParts {
    struct Part {
        let url: URL
        let seconds: TimeInterval
    }

    let items: [Part]
    let workDirectory: URL?

    func cleanUp() {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    static func split(_ url: URL, audioSeconds: TimeInterval) throws -> Qwen3ASRAudioParts {
        let whole = Qwen3ASRAudioParts(items: [Part(url: url, seconds: audioSeconds)], workDirectory: nil)
        guard audioSeconds > Double(Qwen3ASRPrompt.chunkSeconds) else { return whole }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard isPlainMono16kWAV(data) else { return whole }

        let headerSize = 44
        let sampleRate = FileTranscriptionChunker.sampleRate
        let sampleCount = (data.count - headerSize) / MemoryLayout<Int16>.size
        let ranges = FileTranscriptionChunker.ranges(
            totalSamples: sampleCount,
            target: Qwen3ASRPrompt.chunkSeconds * sampleRate
        ) { range in
            FileTranscriptionPipeline.meanMagnitude(in: data, headerSize: headerSize, range: range)
        }
        guard ranges.count > 1 else { return whole }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(TempFileSweeper.prefix + "qwen-\(UUID().uuidString)", isDirectory: true)
        try PrivateFile.ensureDirectory(at: directory)
        do {
            var items: [Part] = []
            for (index, range) in ranges.enumerated() {
                let partURL = directory.appendingPathComponent("part-\(index).wav")
                try FileTranscriptionPipeline.writePart(of: data, headerSize: headerSize, range: range, to: partURL)
                items.append(Part(url: partURL, seconds: Double(range.count) / Double(sampleRate)))
            }
            return Qwen3ASRAudioParts(items: items, workDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The app's own recordings: a 44-byte header, PCM, mono, 16 kHz, 16-bit.
    static func isPlainMono16kWAV(_ data: Data) -> Bool {
        guard data.count > 44 else { return false }
        func ascii(_ offset: Int) -> String { String(decoding: data[offset..<(offset + 4)], as: UTF8.self) }
        func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        return ascii(0) == "RIFF" && ascii(8) == "WAVE" && ascii(12) == "fmt " && ascii(36) == "data"
            && u16(20) == 1 && u16(22) == 1 && u32(24) == 16_000 && u16(34) == 16
    }
}
