#if DEBUG
import AppKit
import Foundation

// Self-tests owned by the "warm" work track: the warm cleanup server and the
// private delivery trail. Keep this track's new assertions here so parallel
// tracks never edit the same test lines.
extension SelfTests {
    static func warmTrackTests() {
        warmServerPolicyTests()
        warmServerCleanupRouteTests()
        warmTranslationServerTests()
        warmDeliveryTrailTests()
    }

    // MARK: - Warm cleanup server

    private static func warmServerPolicyTests() {
        let bundled = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion"
        var config = AppConfig.defaultConfig
        config.cleanup = .clean
        config.keepModelWarm = true

        func plan(
            _ config: AppConfig,
            runtime: String? = bundled,
            verified: Bool = true,
            critical: Bool = false,
            serverExists: Bool = true
        ) -> LlamaServerLaunch? {
            CleanupServerPolicy.launch(
                config: config,
                runtimeBinary: runtime,
                modelVerified: verified,
                modelPath: "/tmp/qwen.gguf",
                memoryPressureCritical: critical,
                launchable: { serverExists ? $0 : nil }
            )
        }

        test("warm.serverRunsOnlyWhenCleanupCanUseIt") {
            expectEqual(
                plan(config),
                LlamaServerLaunch(binary: "/Applications/YappYapp.app/Contents/Resources/bin/llama-server", model: "/tmp/qwen.gguf", contextTokens: LLMCleaner.contextTokens),
                "llama-server sits next to the bundled llama-completion"
            )
            var verbatim = config
            verbatim.cleanup = .verbatim
            expect(plan(verbatim) == nil, "Verbatim never loads the model")
            var cold = config
            cold.keepModelWarm = false
            expect(plan(cold) == nil, "keep the model warm off stops the server")
            expect(plan(config, verified: false) == nil, "no verified model, no server")
            expect(plan(config, critical: true) == nil, "critical memory pressure stops the server")
            expect(plan(config, runtime: nil) == nil, "no runtime, no server")
            expect(plan(config, serverExists: false) == nil, "a bundle without llama-server keeps the one-shot path")
            expect(plan(config, runtime: "/opt/homebrew/bin/llama-cli") == nil, "a user's llama-cli never starts a server")
            var profiled = verbatim
            profiled.appProfiles = [AppProfile(bundleID: "com.apple.mail", appName: "Mail", cleanupMode: CleanupMode.email.rawValue)]
            expect(plan(profiled) != nil, "an app profile that runs the model keeps it warm too")
        }

        test("warm.serverCommandLineCarriesNoUserText") {
            let arguments = CleanupServerPolicy.launchArguments(model: "/tmp/qwen.gguf", port: 50_123, apiPrefix: "/yappyapp-abc")
            expect(arguments.contains("127.0.0.1"), "loopback only")
            expect(arguments.contains("--no-webui"), "no web UI")
            expect(arguments.contains("--log-disable"), "no logs")
            expect(arguments.contains("/yappyapp-abc"), "routes sit behind the per-launch secret")
            expectEqual(arguments.firstIndex(of: "-c").map { arguments[$0 + 1] }, String(LLMCleaner.contextTokens), "same context as the one-shot run")
            expect(!arguments.contains("-sys") && !arguments.contains("-p"), "no prompt on the command line")
        }

        test("warm.requestBodyAndReplyParse") {
            let body = CleanupServerPolicy.requestBody(CleanupServerRequest(system: "rules", user: "words", maxTokens: 64, timeout: 5))
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            expectEqual(json?["temperature"] as? Int, 0, "greedy, like --temp 0")
            expectEqual(json?["max_tokens"] as? Int, 64)
            let messages = json?["messages"] as? [[String: String]]
            expectEqual(messages?.map { $0["role"] ?? "" }, ["system", "user"])
            expectEqual(messages?.last?["content"], "words")
            let reply = Data(#"{"choices":[{"message":{"role":"assistant","content":"Tidy words."}}]}"#.utf8)
            expectEqual(CleanupServerPolicy.replyText(from: reply), "Tidy words.")
            expect(CleanupServerPolicy.replyText(from: Data("oops".utf8)) == nil, "a garbled reply is not text")
            let endpoint = WhisperServerEndpoint(port: 50_123, requestPath: "/yappyapp-abc")
            expectEqual(CleanupServerPolicy.chatURL(endpoint).absoluteString, "http://127.0.0.1:50123/yappyapp-abc/v1/chat/completions")
        }

        test("warm.stoppedControllerIsUnavailable") {
            let controller = LlamaServerController(label: "selftest", warmUp: CleanupServerPolicy.warmUp)
            controller.synchronize(nil)
            expect(!controller.isReady, "nothing runs without a launch")
            expectEqual(
                controller.complete(CleanupServerRequest(system: "s", user: "u", maxTokens: 8, timeout: 1)),
                .unavailable,
                "a stopped server hands the run to llama-completion"
            )
        }
    }

    private final class ServerRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CleanupServerRequest] = []
        private var runs = 0

        func record(_ request: CleanupServerRequest) {
            lock.lock(); stored.append(request); lock.unlock()
        }
        func recordRun() {
            lock.lock(); runs += 1; lock.unlock()
        }
        var requests: [CleanupServerRequest] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        var runCount: Int {
            lock.lock(); defer { lock.unlock() }
            return runs
        }
    }

    private static func warmServerCleanupRouteTests() {
        let spoken = "so um I think we should ship the beta on monday after the standup meeting with the team"
        let tidy = "So I think we should ship the beta on monday after the standup meeting with the team."

        func environment(
            binary: String = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion",
            recorder: ServerRecorder,
            reply: LlamaServerReply
        ) -> CleanupEnvironment {
            var environment = CleanupEnvironment(
                binaryPath: { _ in binary },
                modelReady: { true },
                modelPath: { "/tmp/qwen.gguf" },
                run: { _ in
                    recorder.recordRun()
                    return .finished(status: 0, output: tidy)
                }
            )
            environment.server = { request in
                recorder.record(request)
                return reply
            }
            return environment
        }

        test("warm.cleanupUsesTheWarmServerFirst") {
            let recorder = ServerRecorder()
            let result = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: environment(recorder: recorder, reply: .text(tidy)))
            expectEqual(result, CleanupResult(text: tidy, outcome: .cleaned))
            expectEqual(recorder.runCount, 0, "a warm answer never spawns llama-completion")
            expectEqual(recorder.requests.count, 1)
            expect(recorder.requests.first?.user.contains("ship the beta") == true, "the transcript rides in the request body")
            expectEqual(recorder.requests.first?.system, LLMCleaner.systemPrompt(mode: .clean, protectedTerms: []), "same rules as the one-shot run")
        }

        test("warm.unavailableServerFallsBackToOneShot") {
            let recorder = ServerRecorder()
            let result = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: environment(recorder: recorder, reply: .unavailable))
            expectEqual(result.outcome, .cleaned, "the one-shot helper still cleans")
            expectEqual(recorder.runCount, 1, "exactly one fallback run")
        }

        test("warm.slowServerKeepsWordsAsSpoken") {
            let recorder = ServerRecorder()
            let result = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: environment(recorder: recorder, reply: .timedOut))
            expectEqual(result, CleanupResult(text: spoken, outcome: .fellBack(.timedOut)))
            expectEqual(recorder.runCount, 0, "a timeout does not pay for a second model load")
        }

        test("warm.serverReplyStillPassesAcceptance") {
            let recorder = ServerRecorder()
            let result = LLMCleaner.cleanup(
                text: spoken,
                mode: .clean,
                environment: environment(recorder: recorder, reply: .text("Sure! Here is a summary of your meeting plans."))
            )
            if case .fellBack(.rejected) = result.outcome {
                expectEqual(result.text, spoken, "a rejected rewrite keeps the words as spoken")
            } else {
                expect(false, "an assistant-style reply must be rejected: \(result.outcome)")
            }
        }

        test("warm.userLlamaCliNeverAsksTheServer") {
            let recorder = ServerRecorder()
            _ = LLMCleaner.cleanup(
                text: spoken,
                mode: .clean,
                environment: environment(binary: "/opt/homebrew/bin/llama-cli", recorder: recorder, reply: .text(tidy))
            )
            expect(recorder.requests.isEmpty, "the user's llama-cli runs as chosen")
            expectEqual(recorder.runCount, 1)
        }
    }

    // MARK: - Warm translation server

    private final class TranslationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(LlamaChatRequest, String)] = []
        private var fallbacks = 0

        func record(_ request: LlamaChatRequest, _ model: String) {
            lock.lock(); stored.append((request, model)); lock.unlock()
        }
        func recordFallback() {
            lock.lock(); fallbacks += 1; lock.unlock()
        }
        var requests: [(LlamaChatRequest, String)] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        var fallbackCount: Int {
            lock.lock(); defer { lock.unlock() }
            return fallbacks
        }
    }

    private struct RecordingFallback: TranslationEngine {
        let recorder: TranslationRecorder
        func complete(_ job: TranslationJob) -> TranslationJobResult {
            recorder.recordFallback()
            return .finished("one-shot")
        }
    }

    private static func warmTranslationServerTests() {
        let bundled = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion"
        var config = AppConfig.defaultConfig
        config.translation = .fr
        config.translationModelID = .hyMT2Fast
        config.keepModelWarm = true

        func plan(
            _ config: AppConfig,
            runtime: String? = bundled,
            verified: Set<TranslationModelID> = [.hyMT2Fast, .hyMT2Best],
            critical: Bool = false
        ) -> LlamaServerLaunch? {
            TranslationServerPolicy.launch(
                config: config,
                runtimeBinary: runtime,
                modelVerified: { verified.contains($0) },
                modelPath: { "/m/\($0.rawValue).gguf" },
                memoryPressureCritical: critical,
                launchable: { $0 }
            )
        }

        test("warm.translationServerRunsOnlyWhenATargetCanUseIt") {
            expectEqual(
                plan(config),
                LlamaServerLaunch(
                    binary: "/Applications/YappYapp.app/Contents/Resources/bin/llama-server",
                    model: "/m/hy-mt2-1.8b.gguf",
                    contextTokens: TranslationPrompt.contextTokens
                ),
                "the chosen Hy-MT2 model with the one-shot context"
            )
            var best = config
            best.translationModelID = .hyMT2Best
            expectEqual(plan(best)?.model, "/m/hy-mt2-7b.gguf", "a model change is a different launch")
            var off = config
            off.translation = .off
            expect(plan(off) == nil, "translation off stops the server")
            var cold = config
            cold.keepModelWarm = false
            expect(plan(cold) == nil, "keep the model warm off stops the server")
            expect(plan(config, verified: [.hyMT2Best]) == nil, "an unverified model never loads")
            expect(plan(config, critical: true) == nil, "critical memory pressure stops the server")
            expect(plan(config, runtime: "/opt/homebrew/bin/llama-cli") == nil, "a user's llama-cli never starts a server")
        }

        test("warm.translationRequestIsTheOneShotPrompt") {
            let prompt = TranslationPrompt.make(text: "hola amigos", target: .fr, protectedTerms: [])
            let job = TranslationJob(binaryPath: bundled, modelPath: "/m.gguf", prompt: prompt, maxTokens: 300, timeout: 12)
            let request = TranslationServerPolicy.request(for: job)
            expectEqual(request.messages, [LlamaChatRequest.Message(role: "user", content: prompt)], "no system turn, the prompt as the only user turn")
            let json = (try? JSONSerialization.jsonObject(with: LlamaServerPolicy.requestBody(request))) as? [String: Any]
            expectEqual(json?["temperature"] as? Int, 0, "greedy, like --temp 0")
            expectEqual(json?["repeat_penalty"] as? Double, OneShotLlamaTranslationEngine.repeatPenalty)
            expectEqual(json?["max_tokens"] as? Int, 300)
            let oneShot = OneShotLlamaTranslationEngine.arguments(for: job, runtime: .completion)
            expect(oneShot.contains("--jinja"), "the one-shot run renders the same Jinja template")
            expect(LlamaServerPolicy.launchArguments(model: "/m.gguf", contextTokens: 8, port: 1, apiPrefix: "/p").contains("--jinja"), "so does the server")
            expect(!OneShotLlamaTranslationEngine.arguments(for: job, runtime: .cli).contains("--jinja"), "a user's llama-cli runs as before")
        }

        test("warm.translationAsksTheWarmServerFirst") {
            let job = TranslationJob(binaryPath: bundled, modelPath: "/m.gguf", prompt: "p", maxTokens: 8, timeout: 5)
            func engine(_ reply: LlamaServerReply, _ recorder: TranslationRecorder) -> WarmLlamaTranslationEngine {
                WarmLlamaTranslationEngine(
                    server: { request, model in
                        recorder.record(request, model)
                        return reply
                    },
                    fallback: RecordingFallback(recorder: recorder)
                )
            }
            let warm = TranslationRecorder()
            expectEqual(engine(.text(" Bonjour. [end of text]"), warm).complete(job), .finished("Bonjour."))
            expectEqual(warm.fallbackCount, 0, "a warm answer never spawns llama-completion")
            expectEqual(warm.requests.first?.1, "/m.gguf", "only a server with the job's model answers")
            let cold = TranslationRecorder()
            expectEqual(engine(.unavailable, cold).complete(job), .finished("one-shot"))
            expectEqual(cold.fallbackCount, 1, "not ready means exactly one one-shot run")
            let slow = TranslationRecorder()
            expectEqual(engine(.timedOut, slow).complete(job), .timedOut)
            expectEqual(slow.fallbackCount, 0, "a timeout does not pay for a second model load")
            let cli = TranslationRecorder()
            var cliJob = job
            cliJob.binaryPath = "/opt/homebrew/bin/llama-cli"
            _ = engine(.text("x"), cli).complete(cliJob)
            expect(cli.requests.isEmpty, "the user's llama-cli never asks the server")
        }

        test("warm.serverStatusAndReport") {
            expectEqual(LlamaServerPolicy.status(ready: true, process: true, launching: false, restartPending: false), .ready)
            expectEqual(LlamaServerPolicy.status(ready: false, process: true, launching: true, restartPending: false), .starting)
            expectEqual(LlamaServerPolicy.status(ready: false, process: false, launching: false, restartPending: true), .waitingToRestart)
            expectEqual(LlamaServerPolicy.status(ready: false, process: false, launching: false, restartPending: false), .notRunning)
            let stopped = LlamaServerController(label: "selftest-translation", warmUp: TranslationServerPolicy.warmUp)
            expectEqual(stopped.status, .notRunning)
            expectEqual(stopped.complete(TranslationServerPolicy.warmUp, model: "/m.gguf"), .unavailable)
            var input = SupportReport.currentInput(state: YappYappState(), crashDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
            input.translationServer = .ready
            let report = SupportReport.render(input)
            expect(report.contains("- Warm cleanup server: "), "cleanup server state")
            expect(report.contains("- Warm translation server: ready"), "translation server state next to it")
        }
    }

    // MARK: - Delivery trail

    final class TrailBackend: TranscriptDeliveryBackend {
        var outcome: PasteOutcome = .pastedBestEffort
        var attempt: DeliveryAttempt?
        var lastPasteRestoresClipboard: Bool { attempt?.restoresClipboard ?? false }
        var lastDeliveryAttempt: DeliveryAttempt? { attempt }

        func insertOrCopy(_ text: String, config: AppConfig, target: PasteTarget?) -> PasteOutcome {
            outcome
        }

        @discardableResult
        func copy(_ text: String, purpose: PasteboardWritePurpose) -> Int { 0 }
    }

    private static func warmDeliveryTrailTests() {
        test("warm.trailKeepsTheNewestTwenty") {
            var trail = DeliveryTrail()
            for index in 0..<25 {
                trail.record(DeliveryTrailEntry(
                    date: Date(timeIntervalSince1970: TimeInterval(index)),
                    bundleIdentifier: "app.\(index)",
                    targetKind: .native,
                    decision: "accessibility",
                    outcome: "pasted",
                    activation: .alreadyFrontmost,
                    frontmostMatchedTarget: nil,
                    restoresClipboard: false,
                    secureInputHolder: nil
                ))
            }
            expectEqual(trail.entries.count, DeliveryTrail.capacity)
            expectEqual(trail.entries.first?.bundleIdentifier, "app.5", "the oldest fall off")
            expectEqual(trail.entries.last?.bundleIdentifier, "app.24")
        }

        test("warm.trailLabels") {
            expectEqual(DeliveryTrail.outcomeLabel(.pastedBestEffort), "pastedBestEffort")
            expectEqual(DeliveryTrail.outcomeLabel(.copiedOnly(.modifiersHeld)), "copiedOnly(modifiersHeld)")
            expectEqual(DeliveryTrail.outcomeLabel(.withheld(.secureInputActive)), "withheld(secureInputActive)")
            expectEqual(DeliveryTrail.kindLabel(ClipboardInjector.targetKind(for: "com.mitchellh.ghostty")), "terminal")
        }

        test("warm.deliveryIsRecordedWithoutText") {
            let state = YappYappState()
            let sessions = RecordingSessionCoordinator(state: state, recorder: RecordingController())
            let backend = TrailBackend()
            backend.attempt = DeliveryAttempt(
                decision: "commandV",
                activation: .alreadyFrontmost,
                frontmostMatchedTarget: true,
                restoresClipboard: true
            )
            let delivery = DictationDeliveryCoordinator(
                state: state,
                sessions: sessions,
                backend: backend,
                notifier: FakeDeliveryNotifier()
            )
            delivery.secureInputHolder = { "Ghostty" }
            let target = PasteTarget(application: nil, focusedElement: nil, bundleIdentifier: "com.mitchellh.ghostty")
            delivery.deliver(text: "secret plan for launch day", to: target)
            backend.outcome = .withheld(.secureInputActive)
            backend.attempt = DeliveryAttempt(decision: "withhold(secureInput)", activation: .none, frontmostMatchedTarget: nil, restoresClipboard: false)
            delivery.deliver(text: "my password", to: target)

            let entries = state.deliveryTrail.entries
            expectEqual(entries.count, 2)
            expectEqual(entries.first?.targetKind, .terminal)
            expectEqual(entries.first?.decision, "commandV")
            expectEqual(entries.first?.outcome, "pastedBestEffort")
            expectEqual(entries.first?.frontmostMatchedTarget, true)
            expectEqual(entries.first?.secureInputHolder, nil, "the holder is only asked about when secure input withheld")
            expectEqual(entries.last?.secureInputHolder, "Ghostty")
            let lines = state.deliveryTrail.reportLines()
            expect(lines.allSatisfy { !$0.contains("secret plan") && !$0.contains("password") }, "never the transcript")
            expect(lines.first?.contains("com.mitchellh.ghostty terminal decision=commandV outcome=pastedBestEffort activation=alreadyFrontmost frontmostAfterPaste=target clipboardRestore=on") == true,
                   "one readable line per delivery: \(lines.first ?? "")")
            expect(lines.last?.contains("secureInputHolder=Ghostty") == true, "the secure-input holder is named")

            var input = SupportReport.currentInput(state: state, crashDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
            input.homeDirectory = "/Users/nobody"
            let report = SupportReport.render(input)
            expect(report.contains("## Recent Deliveries"), "the Help support report shows the trail")
            expect(report.contains("decision=commandV"), "with each route")
            expect(!report.contains("secret plan"), "and never the transcript")
        }
    }
}
#endif
