import Foundation

// TRANSLATION (round 2): one translation run. Never throws and never loses a
// dictation: every failure returns the untranslated text with a reason.
// The transcript travels over stdin only, never in argv or a log.

/// One completion request, independent of how llama.cpp is run.
struct TranslationJob: Equatable, Sendable {
    var binaryPath: String
    var modelPath: String
    var prompt: String
    var maxTokens: Int
    var timeout: TimeInterval
}

enum TranslationJobResult: Equatable, Sendable {
    case finished(String)
    case timedOut
    case failed
}

/// How a translation prompt reaches llama.cpp: the warm llama-server
/// (TranslationServer.swift) when it is ready, else a one-shot
/// llama-completion per dictation.
protocol TranslationEngine: Sendable {
    func complete(_ job: TranslationJob) -> TranslationJobResult
}

/// Runs the bundled llama-completion once, prompt on stdin, through the same
/// process runner and watchdog as cleanup.
struct OneShotLlamaTranslationEngine: TranslationEngine {
    /// Shared with the warm server so both runs sample the same way.
    static let repeatPenalty = 1.05

    var run: @Sendable (CleanupInvocation) -> CleanupRunResult = { LLMCleaner.runProcess($0) }

    static func arguments(for job: TranslationJob, runtime: LLMCleaner.Runtime) -> [String] {
        var arguments = [
            "-m", job.modelPath,
            // No -sys: Hy-MT2 has no system prompt. The whole prompt,
            // transcript included, is read from stdin.
            "-f", "/dev/stdin",
            "--single-turn",
            "--no-display-prompt",
            "--no-warmup",
            "--simple-io",
        ]
        if runtime == .cli {
            arguments.append("--log-disable")
        } else {
            // TRANSLATION-WARM: the model's own Jinja chat template, as the
            // warm llama-server renders it: BOS, <hy_User>, prompt,
            // <hy_Assistant>. The legacy built-in Hunyuan template put the
            // user marker after the prompt and no assistant marker, and the
            // 1.8B translated worse with it (measured 2026-10-18).
            arguments.append("--jinja")
        }
        arguments += [
            // Greedy: in testing the model card's temp 0.7 once turned
            // "quinze heures" into 5 p.m.; greedy got 3 p.m. every time.
            "--temp", "0",
            "--repeat-penalty", String(repeatPenalty),
            "-ngl", "99",
            "-c", String(TranslationPrompt.contextTokens),
            "-n", String(job.maxTokens),
        ]
        return arguments
    }

    func complete(_ job: TranslationJob) -> TranslationJobResult {
        let runtime = LLMCleaner.Runtime.of(binaryPath: job.binaryPath)
        // A user-chosen llama-cli echoes the prompt as one "> " line, so the
        // reply can only be cut out of a one-line prompt.
        let input = runtime == .cli ? job.prompt.replacingOccurrences(of: "\n", with: " ") : job.prompt
        let invocation = CleanupInvocation(
            binaryPath: job.binaryPath,
            arguments: Self.arguments(for: job, runtime: runtime),
            input: input,
            timeout: job.timeout
        )
        switch run(invocation) {
        case .timedOut: return .timedOut
        case .launchFailed: return .failed
        case .finished(let status, let output):
            guard status == 0 else { return .failed }
            return .finished(LLMCleaner.extractResponse(fromOutput: output, runtime: runtime))
        }
    }
}

/// Everything a run touches outside pure logic, so tests can swap it.
struct TranslationEnvironment: Sendable {
    var binaryPath: @Sendable (String) -> String?
    var modelReady: @Sendable (TranslationModelID) -> Bool
    var modelPath: @Sendable (TranslationModelID) -> String
    var engine: any TranslationEngine

    static let live = TranslationEnvironment(
        binaryPath: { LLMCleaner.binaryPath(configured: $0) },
        modelReady: { TranslationModelStore.isVerified($0) },
        modelPath: { TranslationModelStore.modelURL(for: $0).path },
        engine: WarmLlamaTranslationEngine()
    )
}

enum Translator {
    /// Translates `text` along `plan`. Blocking (up to the hard timeout):
    /// call it off the main thread. `dictationLanguage` is the Setup pick;
    /// when it already is the target, nothing runs.
    static func translate(
        text: String,
        plan: TranslationPlan,
        dictationLanguage: String = "auto",
        protectedTerms: [String] = [],
        llamaBinaryPath: String = LLMCleaner.stockBinaryPath,
        environment: TranslationEnvironment = .live
    ) -> TranslationResult {
        guard case .model(let id) = plan.route,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              dictationLanguage != plan.target.rawValue else {
            return TranslationResult(text: text, outcome: .skipped)
        }
        guard let binary = environment.binaryPath(llamaBinaryPath) else {
            return TranslationResult(text: text, outcome: .fellBack(.runtimeMissing))
        }
        guard environment.modelReady(id) else {
            return TranslationResult(text: text, outcome: .fellBack(.modelMissing))
        }
        let job = TranslationJob(
            binaryPath: binary,
            modelPath: environment.modelPath(id),
            prompt: TranslationPrompt.make(text: text, target: plan.target, protectedTerms: protectedTerms),
            maxTokens: TranslationPrompt.tokenBudget(for: text),
            timeout: TranslationPrompt.hardTimeout(for: text, model: id)
        )
        switch environment.engine.complete(job) {
        case .timedOut:
            return TranslationResult(text: text, outcome: .fellBack(.timedOut))
        case .failed:
            return TranslationResult(text: text, outcome: .fellBack(.failed))
        case .finished(let reply):
            guard TranslationAcceptance.isAcceptable(original: text, translated: reply) else {
                return TranslationResult(text: text, outcome: .fellBack(.failed))
            }
            return TranslationResult(text: reply, outcome: .translated)
        }
    }
}

// MARK: - Models on disk

// Same pattern as CleanupModelStore: the file is trusted only after its
// checksum (SHA-256 here, from the Hugging Face LFS metadata) passed, and a
// small stamp (digest, size, modification date) saves rehashing gigabytes
// at every launch. The stamp's field is named sha1 for history; it holds the
// SHA-256 for these models.
enum TranslationModelStore {
    static func modelURL(for id: TranslationModelID) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(TranslationCatalog.model(id).download?.filename ?? "none")
    }

    static func stampURL(for id: TranslationModelID) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(".\(modelURL(for: id).lastPathComponent).verified.json")
    }

    static func stagingURL(for id: TranslationModelID) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent("\(modelURL(for: id).lastPathComponent).download")
    }

    static func isInstalled(_ id: TranslationModelID) -> Bool {
        guard TranslationCatalog.model(id).download != nil else { return true }
        return FileManager.default.fileExists(atPath: modelURL(for: id).path)
    }

    static func isVerified(_ id: TranslationModelID) -> Bool {
        guard let download = TranslationCatalog.model(id).download else { return true }
        return CleanupModelStore.isVerified(
            modelURL: modelURL(for: id),
            stampURL: stampURL(for: id),
            expectedSHA1: download.sha256
        )
    }

    @discardableResult
    static func verifyExisting(_ id: TranslationModelID) throws -> Bool {
        guard let download = TranslationCatalog.model(id).download else { return true }
        return try CleanupModelStore.verifyExisting(
            modelURL: modelURL(for: id),
            stampURL: stampURL(for: id),
            expectedSHA1: download.sha256,
            sha1: ModelIntegrity.sha256Hex(for:)
        )
    }

    /// Checks a finished download and moves it into place. A file that fails
    /// the SHA-256 is deleted and never becomes the model.
    static func install(_ id: TranslationModelID, downloadedFile: URL) throws {
        guard let download = TranslationCatalog.model(id).download else { return }
        try CleanupModelStore.install(
            downloadedFile: downloadedFile,
            modelURL: modelURL(for: id),
            stampURL: stampURL(for: id),
            expectedSHA1: download.sha256,
            sha1: ModelIntegrity.sha256Hex(for:)
        )
    }

    static func delete(_ id: TranslationModelID) {
        guard TranslationCatalog.model(id).download != nil else { return }
        let fileManager = FileManager.default
        for url in [modelURL(for: id), stampURL(for: id), stagingURL(for: id)] {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Plain words for a failed download or install.
    static func plainError(_ error: Error) -> String {
        switch error as? CleanupModelError {
        case .checksumMismatch: DownloadErrorCopy.integrity
        case .httpStatus(let code): code >= 500 || code == 429 ? DownloadErrorCopy.serverBusy : DownloadErrorCopy.generic
        case .canceled: L10n.tr("Download canceled.")
        case nil: DownloadErrorCopy.plain(error)
        }
    }
}
