import Foundation

// LLM-CLEANUP-WARM: the cleanup instance of the warm llama-server (see
// LlamaServerController.swift). Measured on an M5 Pro: ~0.8 s per one-shot
// run warm, ~5 s on the first run after a cold start, against ~0.2 s through
// the warm server. Runs while cleanup can run the model, "keep the model
// warm" is on and memory is not critical.

/// One cleanup request for the warm server. The transcript is in `user`.
struct CleanupServerRequest: Sendable {
    var system: String
    var user: String
    var maxTokens: Int
    var timeout: TimeInterval

    var chat: LlamaChatRequest {
        LlamaChatRequest(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            maxTokens: maxTokens,
            timeout: timeout,
            repeatPenalty: nil
        )
    }
}

/// Pure rules, pinned by the self-tests.
enum CleanupServerPolicy {
    static func serverBinaryPath(forRuntimeBinary runtimeBinary: String) -> String {
        LlamaServerPolicy.serverBinaryPath(forRuntimeBinary: runtimeBinary)
    }

    /// Whether any dictation can run the model: the Setup mode or an app
    /// profile that asks for a mode that runs it.
    static func cleanupRunsModel(_ config: AppConfig) -> Bool {
        config.cleanup.usesModel || config.appProfiles.contains { profile in
            profile.cleanupMode.flatMap(CleanupMode.init(rawValue:))?.usesModel ?? false
        }
    }

    /// The server to run, or nil when none should run. `runtimeBinary` is the
    /// one-shot helper the policy resolved for this config.
    static func launch(
        config: AppConfig,
        runtimeBinary: String?,
        modelVerified: Bool,
        modelPath: String,
        memoryPressureCritical: Bool,
        launchable: (String) -> String?
    ) -> LlamaServerLaunch? {
        guard cleanupRunsModel(config), config.keepModelWarm, modelVerified, !memoryPressureCritical,
              let server = LlamaServerPolicy.bundledServer(runtimeBinary: runtimeBinary, launchable: launchable) else {
            return nil
        }
        return LlamaServerLaunch(binary: server, model: modelPath, contextTokens: LLMCleaner.contextTokens)
    }

    static func launchArguments(model: String, port: UInt16, apiPrefix: String) -> [String] {
        LlamaServerPolicy.launchArguments(model: model, contextTokens: LLMCleaner.contextTokens, port: port, apiPrefix: apiPrefix)
    }

    /// The same system rules and user payload the one-shot helper reads.
    static func requestBody(_ request: CleanupServerRequest) -> Data {
        LlamaServerPolicy.requestBody(request.chat)
    }

    static func replyText(from data: Data) -> String? {
        LlamaServerPolicy.replyText(from: data)
    }

    static func chatURL(_ endpoint: WhisperServerEndpoint) -> URL {
        LlamaServerPolicy.chatURL(endpoint)
    }

    /// One token that compiles the kernels and caches the system prompt.
    static var warmUp: LlamaChatRequest {
        CleanupServerRequest(
            system: LLMCleaner.systemPrompt(mode: .clean, protectedTerms: []),
            user: "Warm up.",
            maxTokens: 1,
            timeout: 30
        ).chat
    }
}

extension LlamaServerController {
    /// The warm cleanup model.
    static let cleanup = LlamaServerController(label: "cleanup", warmUp: CleanupServerPolicy.warmUp)

    func complete(_ request: CleanupServerRequest) -> LlamaServerReply {
        complete(request.chat)
    }
}
