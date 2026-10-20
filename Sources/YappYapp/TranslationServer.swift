import Foundation

// TRANSLATION-WARM: the translation instance of the warm llama-server (see
// LlamaServerController.swift). The one-shot llama-completion reloads the
// Hy-MT2 model for every dictation (measured through the app path: 0.9 to
// 1.6 s with 1.8B, 1.3 to 4.1 s with 7B). The warm server keeps the chosen
// model loaded while a translation target is set, its model is verified,
// "keep the model warm" is on and memory is not critical. Choosing the other
// model replaces the server; not ready means the one-shot run, as before.

/// Pure rules, pinned by the self-tests and unit tests.
enum TranslationServerPolicy {
    /// The server to run, or nil when none should run.
    static func launch(
        config: AppConfig,
        runtimeBinary: String?,
        modelVerified: (TranslationModelID) -> Bool,
        modelPath: (TranslationModelID) -> String,
        memoryPressureCritical: Bool,
        launchable: (String) -> String?
    ) -> LlamaServerLaunch? {
        guard case .model(let id) = config.translationPlan.route,
              config.keepModelWarm, !memoryPressureCritical, modelVerified(id),
              let server = LlamaServerPolicy.bundledServer(runtimeBinary: runtimeBinary, launchable: launchable) else {
            return nil
        }
        return LlamaServerLaunch(binary: server, model: modelPath(id), contextTokens: TranslationPrompt.contextTokens)
    }

    /// Exactly what the one-shot run reads: the Hy-MT2 prompt as the only
    /// user turn of the model's own chat template (no system turn), greedy,
    /// the same repeat penalty and token budget.
    static func request(for job: TranslationJob) -> LlamaChatRequest {
        LlamaChatRequest(
            messages: [.init(role: "user", content: job.prompt)],
            maxTokens: job.maxTokens,
            timeout: job.timeout,
            repeatPenalty: OneShotLlamaTranslationEngine.repeatPenalty
        )
    }

    /// One token that compiles the kernels before the first dictation.
    static var warmUp: LlamaChatRequest {
        LlamaChatRequest(
            messages: [.init(role: "user", content: TranslationPrompt.make(text: "Warm up.", target: .en, protectedTerms: []))],
            maxTokens: 1,
            timeout: 60,
            repeatPenalty: OneShotLlamaTranslationEngine.repeatPenalty
        )
    }
}

extension LlamaServerController {
    /// The warm translation model.
    static let translation = LlamaServerController(label: "translation", warmUp: TranslationServerPolicy.warmUp)
}

/// Asks the warm server first and runs the one-shot llama-completion when it
/// is not ready, has another model loaded, or is not the bundled runtime.
struct WarmLlamaTranslationEngine: TranslationEngine {
    var server: @Sendable (LlamaChatRequest, String) -> LlamaServerReply = {
        LlamaServerController.translation.complete($0, model: $1)
    }
    var fallback: any TranslationEngine = OneShotLlamaTranslationEngine()

    func complete(_ job: TranslationJob) -> TranslationJobResult {
        // A llama-cli the user chose never has a server.
        guard LLMCleaner.Runtime.of(binaryPath: job.binaryPath) == .completion else {
            return fallback.complete(job)
        }
        switch server(TranslationServerPolicy.request(for: job), job.modelPath) {
        case .text(let reply):
            return .finished(LLMCleaner.extractResponse(fromOutput: reply, runtime: .completion))
        case .timedOut:
            // The server was warm and still too slow: a one-shot run would
            // only be slower, so the untranslated text goes out on time.
            return .timedOut
        case .unavailable:
            return fallback.complete(job)
        }
    }
}
