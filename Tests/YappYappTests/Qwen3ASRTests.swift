import Foundation
import Testing
@testable import YappYapp

// QWEN3-ASR: catalog pins, prompt and output rules, warm-server policy, the
// transcriber's server-then-CLI flow, long-audio parts and SCAN MY MAC.
// Pure logic and injected helpers only: no model, no network.

private func mac(_ chip: String, _ gb: Int64) -> HardwareProfile {
    HardwareProfile(chipName: chip, modelIdentifier: "Mac", memoryBytes: gb << 30,
                    macOSVersion: "26.1", freeDiskBytes: 200_000_000_000, onBattery: false)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func wavFile(seconds: Double, amplitude: Int16 = 0) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yappyapp-test-qwen-\(UUID().uuidString).wav")
    let writer = try WAVFileWriter(url: url, sampleRate: 16_000, channels: 1)
    let samples = Int(seconds * 16_000)
    var pcm = Data(capacity: samples * 2)
    for index in 0..<samples {
        // A one-second quiet gap every 235 s gives the chunker a place to cut.
        let quiet = (index / 16_000) % 235 == 234
        let value: Int16 = quiet ? 0 : (index % 2 == 0 ? amplitude : -amplitude)
        withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
    }
    try writer.append(pcmBytes: pcm)
    writer.finalize()
    return url
}

// MARK: - Catalog

@Test
func qwen3ASRCatalogEntriesUseTheirOwnScheme() {
    #expect(Qwen3ASRVariant.small.modelPath == "qwen3asr://0.6b")
    #expect(Qwen3ASRVariant.large.modelPath == "qwen3asr://1.7b")
    #expect(Qwen3ASRVariant.from(modelPath: "qwen3asr://1.7b") == .large)
    #expect(Qwen3ASRVariant.from(modelPath: "qwen3asr://9b") == nil)
    #expect(Qwen3ASRVariant.from(modelPath: "parakeet://v3") == nil)

    #expect(ModelCatalog.engine(for: "qwen3asr://0.6b") == .qwen3asr)
    #expect(ModelCatalog.engine(for: "parakeet://v3") == .parakeet)
    #expect(ModelCatalog.engine(for: "/tmp/ggml-base.bin") == .whisper)
    #expect(ModelCatalog.selectedID(for: "qwen3asr://1.7b") == "qwen3asr-1.7b")
    #expect(ModelCatalog.selectedID(for: "qwen3asr://0.6b") == "qwen3asr-0.6b")
    #expect(ModelCatalog.displayName(for: "qwen3asr://1.7b") == "Qwen3-ASR 1.7B")

    for variant in Qwen3ASRVariant.allCases {
        let option = ModelCatalog.options.first { $0.qwen3Variant == variant }
        #expect(option?.engine == .qwen3asr)
        #expect(option?.defaultPath == variant.modelPath)
        #expect(option?.downloadBytes == variant.downloadBytes)
        #expect(option?.filename == "")
    }
    // The main pick and the other families are untouched.
    #expect(ModelCatalog.recommendedID != "qwen3asr-0.6b" && ModelCatalog.recommendedID != "qwen3asr-1.7b")
}

@Test
func qwen3ASRDownloadsArePinnedToVerifiedFiles() {
    let small = Qwen3ASRVariant.small.files
    #expect(small.map(\.filename) == ["Qwen3-ASR-0.6B-Q8_0.gguf", "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"])
    #expect(small.map(\.sizeBytes) == [804_749_248, 214_392_480])
    #expect(small.map(\.sha256) == [
        "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971",
        "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d"
    ])
    let large = Qwen3ASRVariant.large.files
    #expect(large.map(\.filename) == ["Qwen3-ASR-1.7B-Q8_0.gguf", "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"])
    #expect(large.map(\.sizeBytes) == [2_165_034_944, 355_709_344])
    #expect(large.map(\.sha256) == [
        "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57",
        "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d"
    ])
    for variant in Qwen3ASRVariant.allCases {
        #expect(variant.revision.count == 40)
        for file in variant.files {
            #expect(file.url.absoluteString == "https://huggingface.co/\(variant.repo)/resolve/\(variant.revision)/\(file.filename)")
            #expect(file.sha256.count == 64)
        }
        #expect(variant.modelFile.role == .model)
        #expect(variant.projectorFile.role == .projector)
    }
}

@Test
func qwen3ASRProgressCoversBothFilesByBytes() {
    let variant = Qwen3ASRVariant.small
    let model = variant.modelFile
    let projector = variant.projectorFile
    #expect(Qwen3ASRDownloadCoordinator.overallFraction(variant: variant, doneBytes: 0, current: model, fraction: 0) == 0)
    let halfModel = Qwen3ASRDownloadCoordinator.overallFraction(variant: variant, doneBytes: 0, current: model, fraction: 0.5)
    #expect(abs(halfModel - Double(model.sizeBytes) / 2 / Double(variant.downloadBytes)) < 1e-9)
    let done = Qwen3ASRDownloadCoordinator.overallFraction(variant: variant, doneBytes: model.sizeBytes, current: projector, fraction: 1)
    #expect(done == 1)
    #expect(Qwen3ASRDownloadCoordinator.overallFraction(variant: variant, doneBytes: model.sizeBytes, current: projector, fraction: nil) < 1)
}

// MARK: - Prompt and output

@Test
func qwen3ASRLanguageHintFollowsTheDictationLanguage() {
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "auto") == nil)
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "") == nil)
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "xx") == nil)
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "fr") == "language French<asr_text>")
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "EN") == "language English<asr_text>")
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "es") == "language Spanish<asr_text>")
    #expect(Qwen3ASRPrompt.assistantPrefill(language: "nl") == "language Dutch<asr_text>")
    for option in LanguageCatalog.options where option.code != "auto" {
        #expect(Qwen3ASRPrompt.languageName(for: option.code) != nil, "every dictation language has a model-card name")
    }
}

@Test
func qwen3ASRRepliesKeepOnlyTheTranscript() {
    #expect(Qwen3ASRPrompt.transcript(fromReply: "\nlanguage French<asr_text>Bonjour à tous.\n") == "Bonjour à tous.")
    #expect(Qwen3ASRPrompt.transcript(fromReply: "language None<asr_text>") == "")
    #expect(Qwen3ASRPrompt.transcript(fromReply: "language Chinese\n<asr_text>我们开会") == "我们开会")
    #expect(Qwen3ASRPrompt.transcript(fromReply: "Plain text without a header") == "Plain text without a header")
    #expect(Qwen3ASRPrompt.transcript(fromReply: "   ") == "")
    // A looped reply keeps the words once.
    let looped = "language English<asr_text>ok " + String(repeating: "ha", count: 40)
    #expect(Qwen3ASRPrompt.transcript(fromReply: looped) == "ok ha")
    #expect(Qwen3ASRPrompt.collapsingRepetitions("short text") == "short text")
}

@Test
func qwen3ASRBudgetsScaleWithAudio() {
    #expect(Qwen3ASRPrompt.maxTokens(audioSeconds: 0) == 64)
    #expect(Qwen3ASRPrompt.maxTokens(audioSeconds: 10) == 144)
    #expect(Qwen3ASRPrompt.maxTokens(audioSeconds: 10_000) == 3_072)
    // A full part plus its reply stays inside the context.
    let audioTokens = Qwen3ASRPrompt.chunkSeconds * 13
    #expect(audioTokens + Qwen3ASRPrompt.maxTokens(audioSeconds: Double(Qwen3ASRPrompt.chunkSeconds)) < Qwen3ASRPrompt.contextTokens)

    let short = TranscriptionTimeouts.qwen3ASRWatchdog(audioSeconds: 5)
    #expect(short >= TranscriptionTimeouts.whisperWatchdogMinimum)
    let long = TranscriptionTimeouts.qwen3ASRWatchdog(audioSeconds: 1_000)
    #expect(long > TranscriptionTimeouts.cliTimeout(audioSeconds: 1_000, beamSearch: false), "parts each get a model load")
    #expect(TranscriptionWatchdog.timeoutSeconds(isParakeet: false, isLoaded: false, audioSeconds: 5, isQwen3ASR: true) == UInt64(short.rounded(.up)))
}

@Test
func qwen3ASRCommandLineCarriesOnlyPaths() {
    let variant = Qwen3ASRVariant.small
    let arguments = Qwen3ASRCLI.arguments(
        variant: variant,
        modelURL: URL(fileURLWithPath: "/m/model.gguf"),
        projectorURL: URL(fileURLWithPath: "/m/mmproj.gguf"),
        audioPath: "/tmp/yappyapp-rec.wav",
        maxTokens: 200
    )
    #expect(arguments == [
        "-m", "/m/model.gguf", "--mmproj", "/m/mmproj.gguf", "--audio", "/tmp/yappyapp-rec.wav",
        "-f", "/dev/stdin", "--jinja", "--chat-template", Qwen3ASRCLI.chatTemplate,
        "--temp", "0", "-ngl", "99", "-c", "8192", "-n", "200", "--no-warmup"
    ])
    #expect(!arguments.contains("-sys") && !arguments.contains("-p"), "no glossary or context in argv")
    // The fixed template rebuilds the model card's chat from the stdin parts.
    #expect(Qwen3ASRCLI.chatTemplate.contains("<|im_start|>system"))
    #expect(Qwen3ASRCLI.chatTemplate.contains("split('\(Qwen3ASRCLI.partSeparator)')"))
    #expect(Qwen3ASRCLI.stdinPrompt(context: "Genial, Kvellio", prefill: nil)
        == "Genial, Kvellio" + Qwen3ASRCLI.partSeparator + "<__media__>" + Qwen3ASRCLI.partSeparator)
}

// MARK: - Warm server

@Test
func qwen3ASRServerRunsOnlyForAVerifiedWarmQwenModel() {
    var config = AppConfig.defaultConfig
    config.modelPath = Qwen3ASRVariant.large.modelPath
    config.keepModelWarm = true
    let runtime = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion"
    func launch(_ config: AppConfig, verified: Bool = true, critical: Bool = false, runtime: String? = runtime, launchable: Bool = true) -> LlamaServerLaunch? {
        Qwen3ASRServerPolicy.launch(
            config: config,
            runtimeBinary: runtime,
            modelVerified: { _ in verified },
            memoryPressureCritical: critical,
            launchable: { launchable ? $0 : nil }
        )
    }

    let running = launch(config)
    #expect(running?.binary == "/Applications/YappYapp.app/Contents/Resources/bin/llama-server")
    #expect(running?.model == Qwen3ASRModelStore.modelURL(.large).path)
    #expect(running?.projector == Qwen3ASRModelStore.projectorURL(.large).path)
    #expect(running?.contextTokens == 8_192)

    #expect(launch(config, verified: false) == nil)
    #expect(launch(config, critical: true) == nil)
    #expect(launch(config, runtime: "/opt/homebrew/bin/llama-cli") == nil, "a user's llama-cli never runs a server")
    #expect(launch(config, launchable: false) == nil)
    var cold = config
    cold.keepModelWarm = false
    #expect(launch(cold) == nil)
    var parakeet = config
    parakeet.modelPath = "parakeet://v3"
    #expect(launch(parakeet) == nil)
}

@Test
func qwen3ASRServerGetsItsProjectorAndStaysLoopback() {
    let plain = LlamaServerPolicy.launchArguments(model: "/m.gguf", contextTokens: 4_096, port: 5000, apiPrefix: "/abc")
    #expect(!plain.contains("--mmproj"), "cleanup and translation are unchanged")
    let audio = LlamaServerPolicy.launchArguments(model: "/m.gguf", contextTokens: 8_192, port: 5000, apiPrefix: "/abc", projector: "/p.gguf")
    #expect(Array(audio.suffix(2)) == ["--mmproj", "/p.gguf"])
    #expect(Array(audio.dropLast(2)) == LlamaServerPolicy.launchArguments(model: "/m.gguf", contextTokens: 8_192, port: 5000, apiPrefix: "/abc"))
    #expect(audio.contains("127.0.0.1") && audio.contains("--no-webui") && audio.contains("--log-disable"))
}

@Test
func qwen3ASRRequestFollowsTheModelCard() throws {
    let wav = Qwen3ASRServerPolicy.silentWAV(seconds: 0.5)
    #expect(wav.count == 44 + 16_000)
    #expect(Qwen3ASRAudioParts.isPlainMono16kWAV(wav))

    let body = Qwen3ASRServerPolicy.requestBody(wav: wav, context: "YappYapp, Genial", prefill: "language French<asr_text>", maxTokens: 99)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["temperature"] as? Int == 0)
    #expect(json["max_tokens"] as? Int == 99)
    #expect(json["stream"] as? Bool == false)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant"])
    #expect(messages[0]["content"] as? String == "YappYapp, Genial")
    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(parts.count == 1, "the user turn is the audio alone")
    #expect(parts[0]["type"] as? String == "input_audio")
    let audio = try #require(parts[0]["input_audio"] as? [String: String])
    #expect(audio["data"] == wav.base64EncodedString())
    #expect(messages[2]["content"] as? String == "language French<asr_text>")

    let auto = Qwen3ASRServerPolicy.requestBody(wav: wav, context: "", prefill: nil, maxTokens: 1)
    let autoJSON = try #require(try JSONSerialization.jsonObject(with: auto) as? [String: Any])
    #expect((autoJSON["messages"] as? [[String: Any]])?.count == 2, "AUTO lets the model detect the language")
}

// MARK: - Transcriber flow

@Test
func qwen3ASRUsesTheWarmServerThenTheOneShotHelper() async throws {
    let url = try wavFile(seconds: 2, amplitude: 2_000)
    defer { try? FileManager.default.removeItem(at: url) }
    let glossary = Glossary(entries: [GlossaryEntry(canonical: "YappYapp", variants: ["yap yap"], notes: nil)])
    var config = AppConfig.defaultConfig
    config.modelPath = Qwen3ASRVariant.small.modelPath
    config.language = "fr"
    let calls = Calls()

    var warm = Qwen3ASRTranscriber()
    warm.server = { body, _, model in
        calls.add("server:\(model.hasSuffix("Qwen3-ASR-0.6B-Q8_0.gguf"))")
        let text = String(decoding: body, as: UTF8.self)
        calls.add(text.contains("language French<asr_text>") ? "prefill" : "no-prefill")
        calls.add(text.contains("YappYapp") ? "context" : "no-context")
        return .text("language French<asr_text>bonjour yap yap")
    }
    warm.runCLI = { _, _, _, _ in calls.add("cli"); return "" }
    warm.cliBinary = { _ in "/bin/echo" }
    let text = try await warm.transcribe(audioURL: url, variant: .small, config: config, glossary: glossary, audioSeconds: 2)
    #expect(text == "bonjour YappYapp")
    #expect(calls.all == ["server:true", "prefill", "context"])

    let fallback = Calls()
    var cold = Qwen3ASRTranscriber()
    cold.server = { _, _, _ in .unavailable }
    cold.cliBinary = { _ in "/bundle/llama-mtmd-cli" }
    cold.runCLI = { binary, arguments, prompt, timeout in
        fallback.add(binary)
        fallback.add(arguments.contains(url.path) ? "audio-path" : "missing-path")
        // WORDS-AS-HINTS: the one-shot helper gets the same context and
        // language prefill as the warm server, over stdin only.
        fallback.add(prompt == Qwen3ASRCLI.stdinPrompt(context: "YappYapp", prefill: "language French<asr_text>") ? "stdin-context" : "no-context")
        fallback.add(arguments.contains { $0.hasPrefix("YappYapp") || $0.contains(Qwen3ASRCLI.mediaMarker + Qwen3ASRCLI.partSeparator) } ? "context-in-argv" : "argv-clean")
        fallback.add(timeout >= TranscriptionTimeouts.cliMinimum ? "budget" : "short")
        return "\nlanguage English<asr_text>hello there\n"
    }
    let coldText = try await cold.transcribe(audioURL: url, variant: .small, config: config, glossary: glossary, audioSeconds: 2)
    #expect(coldText == "hello there")
    #expect(fallback.all == ["/bundle/llama-mtmd-cli", "audio-path", "stdin-context", "argv-clean", "budget"])
}

@Test
func qwen3ASRReportsSilenceTimeoutsAndAMissingRuntime() async throws {
    let url = try wavFile(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let glossary = Glossary(entries: [])
    var config = AppConfig.defaultConfig
    config.modelPath = Qwen3ASRVariant.small.modelPath

    var silent = Qwen3ASRTranscriber()
    silent.server = { _, _, _ in .text("language None<asr_text>") }
    await #expect(throws: WhisperError.self) {
        _ = try await silent.transcribe(audioURL: url, variant: .small, config: config, glossary: glossary, audioSeconds: 1)
    }

    let cliCalls = Calls()
    var busy = Qwen3ASRTranscriber()
    busy.server = { _, _, _ in .timedOut }
    busy.runCLI = { _, _, _, _ in cliCalls.add("cli"); return "" }
    do {
        _ = try await busy.transcribe(audioURL: url, variant: .small, config: config, glossary: glossary, audioSeconds: 1)
        Issue.record("a timed-out server must not return text")
    } catch WhisperError.timedOut {
    } catch {
        Issue.record("unexpected error \(error)")
    }
    #expect(cliCalls.all.isEmpty, "a busy server never starts a second full model")

    var missing = Qwen3ASRTranscriber()
    missing.server = { _, _, _ in .unavailable }
    missing.cliBinary = { _ in nil }
    await #expect(throws: Qwen3ASRError.runtimeMissing) {
        _ = try await missing.transcribe(audioURL: url, variant: .small, config: config, glossary: glossary, audioSeconds: 1)
    }
}

@Test
func qwen3ASRCutsLongRecordingsIntoPartsAtQuietMoments() throws {
    let short = try wavFile(seconds: 3, amplitude: 1_000)
    defer { try? FileManager.default.removeItem(at: short) }
    let single = try Qwen3ASRAudioParts.split(short, audioSeconds: 3)
    #expect(single.items.count == 1 && single.items[0].url == short && single.workDirectory == nil)

    let long = try wavFile(seconds: 600, amplitude: 1_000)
    defer { try? FileManager.default.removeItem(at: long) }
    let parts = try Qwen3ASRAudioParts.split(long, audioSeconds: 600)
    #expect(parts.items.count == 3)
    #expect(abs(parts.items.reduce(0) { $0 + $1.seconds } - 600) < 0.001, "no audio is lost or repeated")
    for part in parts.items {
        #expect(part.seconds <= Double(Qwen3ASRPrompt.chunkSeconds))
        #expect(FileManager.default.fileExists(atPath: part.url.path))
    }
    // The first cut lands in the quiet second at 234 to 235 s.
    #expect(parts.items[0].seconds > 234 && parts.items[0].seconds < 235)
    let directory = try #require(parts.workDirectory)
    #expect(directory.lastPathComponent.hasPrefix(TempFileSweeper.prefix))
    parts.cleanUp()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

// MARK: - App rules

@Test
func qwen3ASRReadinessAndMemoryRules() {
    var config = AppConfig.defaultConfig
    config.modelPath = Qwen3ASRVariant.small.modelPath
    let option = ModelCatalog.option(for: "qwen3asr-0.6b")
    let missing = RecordingPrerequisite.evaluate(config: config, selectedOption: option, selectedModelInstalled: false,
                                                 downloadProgress: nil, whisperReadiness: (false, false))
    if case .missingModel(let notice) = missing {
        #expect(notice.modelID == "qwen3asr-0.6b")
    } else {
        Issue.record("an undownloaded Qwen3-ASR model asks for its download")
    }
    let noRuntime = RecordingPrerequisite.evaluate(config: config, selectedOption: option, selectedModelInstalled: true,
                                                   downloadProgress: nil, whisperReadiness: (false, false), qwen3RuntimeAvailable: false)
    #expect(noRuntime == .blocked(Qwen3ASRError.runtimeMissing.localizedDescription))
    let ready = RecordingPrerequisite.evaluate(config: config, selectedOption: option, selectedModelInstalled: true,
                                               downloadProgress: nil, whisperReadiness: (false, false))
    #expect(ready == .ready, "Whisper's runtime does not matter to Qwen3-ASR")

    let snapshot = ModelReadinessPresenter.snapshot(config: config, whisperReadiness: (false, false),
                                                    selectedModelInstalled: true, qwen3RuntimeAvailable: true)
    #expect(snapshot.isModelReady && snapshot.isWhisperReady)
    #expect(snapshot.selectedModelName == "Qwen3-ASR 0.6B")

    #expect(ParakeetMemoryPolicy.action(engine: .qwen3asr, parakeetVariant: nil, selectedInstalled: true,
                                        keepModelWarm: true, atLaunch: true) == .release)

    // Whisper's built-in translate cannot run, so the translation model does.
    let plan = TranslationPlan.make(target: .en, chosen: .whisperBuiltIn, engine: .qwen3asr)
    #expect(plan.route == .model(TranslationCatalog.defaultModelID) && plan.substitutedForWhisper)

    #expect(SupportReport.modelFileLabel("qwen3asr://1.7b") == "qwen3asr://1.7b")
    #expect(ManagedOverrides.modelPath(forManagedSelection: "qwen3asr-1.7b") == "qwen3asr://1.7b")
    #expect(ManagedOverrides.modelPath(forManagedSelection: "qwen3asr://0.6b") == "qwen3asr://0.6b")
    #expect(ManagedOverrides.modelPath(forManagedSelection: "qwen3asr://9b") == nil)
    #expect(!DictationBadge.detectsLanguageItself("qwen3asr://0.6b"), "the badge shows the picked language")
}

@Test
func qwen3ASRModelsGroupAndDeleteRules() {
    #expect(ModelGroup.qwen3asr.title(count: 2) == "QWEN3-ASR (2)")
    #expect(ModelGroup.qwen3asr.detail == "52 LANGUAGES")
    #expect(!ModelListPolicy.qwen3ASROpensByDefault(selectedID: "parakeet-v3", downloads: [:], errors: [:]))
    #expect(ModelListPolicy.qwen3ASROpensByDefault(selectedID: "qwen3asr-1.7b", downloads: [:], errors: [:]))
    #expect(ModelListPolicy.qwen3ASROpensByDefault(selectedID: "parakeet-v3", downloads: ["qwen3asr-0.6b": 0.2], errors: [:]))
    #expect(ModelListPolicy.qwen3ASROpensByDefault(selectedID: "parakeet-v3", downloads: [:], errors: ["qwen3asr-0.6b": "x"]))
    #expect(!ModelListPolicy.qwen3ASROpensByDefault(selectedID: "large-v3-turbo", downloads: ["small": 0.1], errors: [:]))
    #expect(!ModelListPolicy.whisperOpensByDefault(selectedID: "qwen3asr-0.6b", downloads: [:], errors: [:]), "Qwen3-ASR is its own family")

    #expect(ModelRowDelete.isOffered(isInstalled: true, isSelected: false, downloadProgress: nil))
    #expect(!ModelRowDelete.isOffered(isInstalled: true, isSelected: true, downloadProgress: nil), "never the model in use")
    #expect(!ModelRowDelete.isOffered(isInstalled: false, isSelected: false, downloadProgress: nil))
    #expect(!ModelRowDelete.isOffered(isInstalled: true, isSelected: false, downloadProgress: 0.5))
}

@Test
func scanMyMacNamesAQwen3ASRSizeWithoutChangingTheSpeechPick() {
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M5 Pro", 48)) == .large)
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M4", 16)) == .large)
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M3 Pro", 18)) == .large)
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M3", 16)) == .small, "base M3 is not enough")
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M2 Max", 32)) == .small, "older than M3 Pro")
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M4", 8)) == .small, "under 16 GB")
    #expect(ModelAdvisor.qwen3ASRVariant(for: mac("Apple M1", 8)) == .small)

    for profile in [mac("Apple M5 Pro", 48), mac("Apple M1", 8), mac("Apple M2", 16)] {
        let speech = ModelAdvisor.recommend(for: profile).first { $0.kind == .speech }
        #expect(speech?.choice == .speech(modelID: ModelCatalog.recommendedID), "the speech pick is unchanged")
        let size = ModelAdvisor.qwen3ASRVariant(for: profile) == .large ? "1.7B" : "0.6B"
        #expect(speech?.reason.hasSuffix("Qwen3-ASR \(size).") == true)
    }
}
