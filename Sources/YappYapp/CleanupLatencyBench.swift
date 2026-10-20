#if DEBUG
import Foundation

// LLM-CLEANUP-WARM: developer timing harness behind --llm-cleanup-latency.
// Fixed English fixtures, the installed cleanup model, timings on stdout.
enum CleanupLatencyBench {
    static let fixtures = [
        "um so i think we should move the launch to thursday because the design is done but the copy needs one more pass",
        "can you send me the slides from yesterday uh i want to check the numbers before the call with the client tomorrow morning",
        "the build is green now and uh the tests pass so i will merge the branch after lunch if nobody objects to it",
        "remind me to buy milk eggs and bread on the way home and also to call my mom about the weekend plans please",
        "we hit the rate limit again so um lets add a retry with backoff and log the status code when it fails next time"
    ]

    static func run(completionBinary: String) -> Never {
        let modelPath = LLMCleaner.modelURL.path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            print("latency.error=model missing")
            exit(2)
        }
        let oneShot = CleanupEnvironment(
            binaryPath: { _ in completionBinary },
            modelReady: { true },
            modelPath: { modelPath },
            run: { LLMCleaner.runProcess($0) }
        )
        for (index, text) in fixtures.enumerated() {
            report("oneShot", index, oneShot, text)
        }

        let server = LlamaServerController.cleanup
        let launchedAt = Date()
        server.synchronize(LlamaServerLaunch(
            binary: CleanupServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: modelPath,
            contextTokens: LLMCleaner.contextTokens
        ))
        server.waitUntilReady()
        print("latency.server.launchToReadyIncludingWarmUp=\(milliseconds(since: launchedAt))ms ready=\(server.isReady)")
        var warm = oneShot
        warm.server = { server.complete($0) }
        for (index, text) in fixtures.enumerated() {
            report("server", index, warm, text)
        }
        server.stop()
        exit(0)
    }

    private static func report(_ label: String, _ index: Int, _ environment: CleanupEnvironment, _ text: String) {
        let startedAt = Date()
        let result = LLMCleaner.cleanup(text: text, mode: .clean, environment: environment)
        print("latency.\(label).run\(index + 1)=\(milliseconds(since: startedAt))ms outcome=\(result.outcome)")
    }

    static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

// TRANSLATION-WARM: the same harness for translation, behind
// --translation-latency <llama-completion> <model.gguf> <model id>. The
// fixtures go into French through Translator.translate, first one-shot, then
// through the warm server. Timings and outcomes only, never text.
enum TranslationLatencyBench {
    static func run(completionBinary: String, modelPath: String, modelID: String) -> Never {
        guard FileManager.default.fileExists(atPath: modelPath),
              let id = TranslationModelID(rawValue: modelID), id != .whisperBuiltIn else {
            print("latency.error=model missing or unknown id")
            exit(2)
        }
        let plan = TranslationPlan.make(target: .fr, chosen: id, engine: .parakeet)
        func environment(_ engine: any TranslationEngine) -> TranslationEnvironment {
            TranslationEnvironment(
                binaryPath: { _ in completionBinary },
                modelReady: { _ in true },
                modelPath: { _ in modelPath },
                engine: engine
            )
        }
        let oneShot = environment(OneShotLlamaTranslationEngine())
        let oneShotTexts = CleanupLatencyBench.fixtures.enumerated().map { index, text in
            report("oneShot", index, oneShot, plan, text, sameAs: nil)
        }

        let server = LlamaServerController.translation
        let launchedAt = Date()
        server.synchronize(LlamaServerLaunch(
            binary: LlamaServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: modelPath,
            contextTokens: TranslationPrompt.contextTokens
        ))
        server.waitUntilReady()
        print("latency.server.launchToReadyIncludingWarmUp=\(CleanupLatencyBench.milliseconds(since: launchedAt))ms ready=\(server.isReady)")
        // A fallback here would time the one-shot run again: fail loudly.
        let warm = environment(WarmLlamaTranslationEngine(fallback: Unreachable()))
        for (index, text) in CleanupLatencyBench.fixtures.enumerated() {
            report("server", index, warm, plan, text, sameAs: oneShotTexts[index])
        }
        server.stop()
        exit(0)
    }

    private struct Unreachable: TranslationEngine {
        func complete(_ job: TranslationJob) -> TranslationJobResult { .failed }
    }

    /// Prints whether the warm reply equals the one-shot reply, never the text.
    @discardableResult
    private static func report(
        _ label: String,
        _ index: Int,
        _ environment: TranslationEnvironment,
        _ plan: TranslationPlan,
        _ text: String,
        sameAs oneShot: String?
    ) -> String {
        let startedAt = Date()
        let result = Translator.translate(text: text, plan: plan, dictationLanguage: "en", environment: environment)
        let elapsed = CleanupLatencyBench.milliseconds(since: startedAt)
        let same = oneShot.map { " sameAsOneShot=\($0 == result.text)" } ?? ""
        print("latency.\(label).run\(index + 1)=\(elapsed)ms outcome=\(result.outcome)\(same)")
        return result.text
    }
}
#endif
