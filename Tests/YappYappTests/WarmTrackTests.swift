import Foundation
import Testing
@testable import YappYapp

// The warm cleanup server, the delivery trail and FILES kept apart from MIC.

@Test
func fileResultWordingNeverPromisesTheClipboard() {
    let done = FileTranscriptionPresenter.detail(for: .finished(fileName: "a.m4a", words: 3))
    #expect(done.contains("3"))
    #expect(!done.uppercased().contains("COPIED"))
    #expect(!done.uppercased().contains("HISTORY"))
    #expect(!FileTranscriptionPresenter.detail(for: .canceled(fileName: "a")).uppercased().contains("COPIED"))
}

@Test
func cleanupServerSitsNextToItsCompletionHelper() {
    #expect(CleanupServerPolicy.serverBinaryPath(forRuntimeBinary: "/A/YappYapp.app/Contents/Resources/bin/llama-completion")
        == "/A/YappYapp.app/Contents/Resources/bin/llama-server")
}

@Test
func cleanupServerNeedsWarmModelAndBundledRuntime() {
    var config = AppConfig.defaultConfig
    config.cleanup = .clean
    config.keepModelWarm = true
    let runtime = "/A/YappYapp.app/Contents/Resources/bin/llama-completion"
    func plan(_ config: AppConfig, runtime: String? = runtime, critical: Bool = false) -> LlamaServerLaunch? {
        CleanupServerPolicy.launch(
            config: config,
            runtimeBinary: runtime,
            modelVerified: true,
            modelPath: "/tmp/m.gguf",
            memoryPressureCritical: critical,
            launchable: { $0 }
        )
    }
    #expect(plan(config)?.binary.hasSuffix("/llama-server") == true)
    #expect(plan(config, critical: true) == nil)
    #expect(plan(config, runtime: "/opt/homebrew/bin/llama-cli") == nil)
    var cold = config
    cold.keepModelWarm = false
    #expect(plan(cold) == nil)
    var verbatim = config
    verbatim.cleanup = .verbatim
    #expect(plan(verbatim) == nil)
}

@Test
func cleanupServerArgumentsArePinnedToLoopback() {
    let arguments = CleanupServerPolicy.launchArguments(model: "/tmp/m.gguf", port: 4242, apiPrefix: "/yappyapp-x")
    #expect(arguments.contains("--host"))
    #expect(arguments[arguments.firstIndex(of: "--host")! + 1] == "127.0.0.1")
    #expect(arguments.contains("--no-webui"))
    #expect(arguments.contains("--log-disable"))
}

@Test
func deliveryTrailIsARingOfTwenty() {
    var trail = DeliveryTrail()
    for index in 0..<30 {
        trail.record(DeliveryTrailEntry(
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            bundleIdentifier: "b\(index)",
            targetKind: .terminal,
            decision: "commandV",
            outcome: DeliveryTrail.outcomeLabel(.pastedBestEffort),
            activation: .alreadyFrontmost,
            frontmostMatchedTarget: false,
            restoresClipboard: true,
            secureInputHolder: nil
        ))
    }
    #expect(trail.entries.count == 20)
    #expect(trail.entries.first?.bundleIdentifier == "b10")
    let line = trail.reportLines().last ?? ""
    #expect(line.contains("b29 terminal decision=commandV outcome=pastedBestEffort"))
    #expect(line.contains("frontmostAfterPaste=other app"))
}

// TRANSLATION-WARM: the second instance of the warm llama-server.

@Test
func translationServerFollowsTargetModelAndKeepWarm() {
    var config = AppConfig.defaultConfig
    config.translation = .de
    config.translationModelID = .hyMT2Best
    config.keepModelWarm = true
    let runtime = "/A/YappYapp.app/Contents/Resources/bin/llama-completion"
    func plan(_ config: AppConfig, verified: Bool = true, critical: Bool = false) -> LlamaServerLaunch? {
        TranslationServerPolicy.launch(
            config: config,
            runtimeBinary: runtime,
            modelVerified: { _ in verified },
            modelPath: { "/m/\($0.rawValue).gguf" },
            memoryPressureCritical: critical,
            launchable: { $0 }
        )
    }
    #expect(plan(config) == LlamaServerLaunch(
        binary: "/A/YappYapp.app/Contents/Resources/bin/llama-server",
        model: "/m/hy-mt2-7b.gguf",
        contextTokens: TranslationPrompt.contextTokens
    ))
    #expect(plan(config, verified: false) == nil)
    #expect(plan(config, critical: true) == nil)
    var off = config
    off.translation = .off
    #expect(plan(off) == nil)
    var cold = config
    cold.keepModelWarm = false
    #expect(plan(cold) == nil)
}

@Test
func translationServerRequestMatchesOneShotPrompt() {
    let prompt = TranslationPrompt.make(text: "goeie morgen", target: .en, protectedTerms: ["YappYapp"])
    let job = TranslationJob(binaryPath: "/x/llama-completion", modelPath: "/m.gguf", prompt: prompt, maxTokens: 256, timeout: 9)
    let request = TranslationServerPolicy.request(for: job)
    #expect(request.messages.count == 1)
    #expect(request.messages.first?.role == "user")
    #expect(request.messages.first?.content == prompt)
    #expect(request.maxTokens == 256)
    #expect(request.timeout == 9)
    #expect(request.repeatPenalty == OneShotLlamaTranslationEngine.repeatPenalty)
    let arguments = LlamaServerPolicy.launchArguments(model: "/m.gguf", contextTokens: 8_192, port: 4242, apiPrefix: "/p")
    #expect(!arguments.joined(separator: " ").contains("goeie"))
    #expect(arguments.contains("--jinja"))
}

@Test
func llamaServerStatusNamesEachState() {
    #expect(LlamaServerPolicy.status(ready: true, process: true, launching: false, restartPending: false).rawValue == "ready")
    #expect(LlamaServerPolicy.status(ready: false, process: false, launching: true, restartPending: false).rawValue == "starting")
    #expect(LlamaServerPolicy.status(ready: false, process: false, launching: false, restartPending: true).rawValue == "waiting to restart")
    #expect(LlamaServerPolicy.status(ready: false, process: false, launching: false, restartPending: false).rawValue == "not running")
}
