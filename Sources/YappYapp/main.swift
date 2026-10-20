import AppKit

#if DEBUG
if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated {
        SelfTests.run()
    }
}

// RENDER-GALLERY: offscreen PNGs of every tab and key state for visual QA.
if let galleryIndex = CommandLine.arguments.firstIndex(of: "--render-gallery") {
    let pathIndex = CommandLine.arguments.index(after: galleryIndex)
    guard CommandLine.arguments.indices.contains(pathIndex) else {
        FileHandle.standardError.write(Data("usage: --render-gallery <dir>\n".utf8))
        exit(2)
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[pathIndex])
    exit(MainActor.assumeIsolated { RenderGallery.run(outputDirectory: directory) })
}

if CommandLine.arguments.contains("--route-change-test") {
    RouteChangeTest.run()
}

if CommandLine.arguments.contains("--route-change-list-devices") {
    RouteChangeTest.printDevices()
}

if CommandLine.arguments.contains("--prepare-support") {
    do {
        try ConfigStore().prepareApplicationSupport()
        print("supportDirectory=\(AppPaths.supportDirectory.path)")
        print("config=\(AppPaths.configURL.path)")
        print("glossary=\(AppPaths.glossaryURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("prepare-support failed: \(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--accessibility-stale-status") {
    PermissionDiagnostics.printStaleVerdict()
}

if CommandLine.arguments.contains("--setup-readiness-status") {
    SetupReadinessDiagnostics.printStatus()
    exit(0)
}

if CommandLine.arguments.contains("--recording-smoke") {
    RecordingDiagnostics.runSmoke()
}

if CommandLine.arguments.contains("--transcription-smoke") {
    TranscriptionDiagnostics.runSmoke()
}

if CommandLine.arguments.contains("--paste-smoke") {
    PasteDiagnostics.runSmoke()
}

if CommandLine.arguments.contains("--cmdv-smoke") {
    PasteDiagnostics.runCommandVSmoke()
}

// LLM-CLEANUP-WARM: times cleanup through the production code, first the
// one-shot llama-completion and then the warm llama-server next to it.
// Prints timings and outcomes only, never text. Usage:
// --llm-cleanup-latency /path/to/llama-completion
if let benchIndex = CommandLine.arguments.firstIndex(of: "--llm-cleanup-latency"),
   CommandLine.arguments.indices.contains(benchIndex + 1) {
    CleanupLatencyBench.run(completionBinary: CommandLine.arguments[benchIndex + 1])
}

// TRANSLATION-WARM: the same for translation. Usage:
// --translation-latency /path/to/llama-completion /path/to/model.gguf hy-mt2-1.8b
if let benchIndex = CommandLine.arguments.firstIndex(of: "--translation-latency"),
   CommandLine.arguments.indices.contains(benchIndex + 3) {
    TranslationLatencyBench.run(
        completionBinary: CommandLine.arguments[benchIndex + 1],
        modelPath: CommandLine.arguments[benchIndex + 2],
        modelID: CommandLine.arguments[benchIndex + 3]
    )
}

// QWEN3-ASR-WARM: the same for the Qwen3-ASR speech engine. Usage:
// --qwen3asr-latency /path/to/llama-completion 0.6b auto a.wav b.wav
if let benchIndex = CommandLine.arguments.firstIndex(of: "--qwen3asr-latency"),
   CommandLine.arguments.indices.contains(benchIndex + 4) {
    Qwen3ASRLatencyBench.run(
        completionBinary: CommandLine.arguments[benchIndex + 1],
        variantName: CommandLine.arguments[benchIndex + 2],
        language: CommandLine.arguments[benchIndex + 3],
        wavs: Array(CommandLine.arguments[(benchIndex + 4)...])
    )
}

#if DEBUG
// WORDS-NEAR-MISS: cleanup accuracy and model time on synthetic fixtures,
// before and after the near-miss changes. Usage:
// --words-cleanup-eval /path/to/llama-completion /path/to/model.gguf cases.json
if let evalIndex = CommandLine.arguments.firstIndex(of: "--words-cleanup-eval"),
   CommandLine.arguments.indices.contains(evalIndex + 3) {
    WordsCleanupEval.run(
        completionBinary: CommandLine.arguments[evalIndex + 1],
        modelPath: CommandLine.arguments[evalIndex + 2],
        casesPath: CommandLine.arguments[evalIndex + 3]
    )
}

// NUMBERS: number styles with cleanup off and on, on synthetic fixtures. Usage:
// --numbers-cleanup-eval /path/to/llama-completion /path/to/model.gguf cases.json
if let evalIndex = CommandLine.arguments.firstIndex(of: "--numbers-cleanup-eval"),
   CommandLine.arguments.indices.contains(evalIndex + 3) {
    NumbersCleanupEval.run(
        completionBinary: CommandLine.arguments[evalIndex + 1],
        modelPath: CommandLine.arguments[evalIndex + 2],
        casesPath: CommandLine.arguments[evalIndex + 3]
    )
}

// WORDS-AS-HINTS: Qwen3-ASR with and without the words as context. Usage:
// --qwen3asr-hint-check /path/to/llama-completion 0.6b en words.json a.wav b.wav
if let hintIndex = CommandLine.arguments.firstIndex(of: "--qwen3asr-hint-check"),
   CommandLine.arguments.indices.contains(hintIndex + 5) {
    Qwen3ASRHintCheck.run(
        completionBinary: CommandLine.arguments[hintIndex + 1],
        variantName: CommandLine.arguments[hintIndex + 2],
        language: CommandLine.arguments[hintIndex + 3],
        wordsPath: CommandLine.arguments[hintIndex + 4],
        wavs: Array(CommandLine.arguments[(hintIndex + 5)...])
    )
}
#endif

// LLM-CLEANUP: end-to-end smoke for the optional local tidy pass. Prints the
// resolved binary/model state and, when both exist, runs a real cleanup on the
// provided text (or a builtin fixture) through the exact production path.
if let smokeIndex = CommandLine.arguments.firstIndex(of: "--llm-cleanup-smoke") {
    let nextIndex = CommandLine.arguments.index(after: smokeIndex)
    let sample = CommandLine.arguments.indices.contains(nextIndex)
        ? CommandLine.arguments[nextIndex]
        : "so um i think we should uh ship the beta on monday no wait on tuesday after the standup"

    let loadedConfig = try? ConfigStore().load()
    let configured = loadedConfig?.llamaBinaryPath ?? LLMCleaner.stockBinaryPath
    let mode = CommandLine.arguments.firstIndex(of: "--mode")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CleanupMode(rawValue: CommandLine.arguments[$0 + 1]) : nil }
        ?? .clean
    let binary = LLMCleaner.binaryPath(configured: configured)
    print("llmCleanup.binary=\(binary ?? "missing")")
    print("llmCleanup.runtime=\(binary.map { LLMCleaner.Runtime.of(binaryPath: $0) == .completion ? "llama-completion" : "llama-cli" } ?? "missing")")
    print("llmCleanup.model=\(LLMCleaner.isModelInstalled() ? LLMCleaner.modelURL.path : "missing")")
    print("llmCleanup.verified=\(CleanupModelStore.isVerified())")
    print("llmCleanup.mode=\(mode.rawValue)")

    if binary != nil, LLMCleaner.isModelInstalled() {
        let startedAt = Date()
        let result = LLMCleaner.cleanup(text: sample, mode: mode, llamaBinaryPath: configured)
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
        print("llmCleanup.elapsed=\(elapsed)")
        print("llmCleanup.outcome=\(result.outcome)")
        print("llmCleanup.changed=\(result.text != sample)")
        print("llmCleanup.input=\(sample)")
        print("llmCleanup.output=\(result.text)")
        exit(result.outcome == .cleaned ? 0 : 2)
    }
    exit(2)
}
#endif

// These diagnostics intentionally remain in packaged builds. The release
// verifier uses --launch-smoke, while doctor/support tooling needs the two
// read-only status commands below. Test harnesses and content-printing smoke
// commands above are compiled only in DEBUG builds.
if CommandLine.arguments.contains("--permissions-status") {
    PermissionDiagnostics.printSnapshot()
}

// L10N (YA-42): read-only; prints where the translation tables were found.
if CommandLine.arguments.contains("--l10n-status") {
    L10nDiagnostics.printStatus()
}

if let cacheStatusIndex = CommandLine.arguments.firstIndex(of: "--parakeet-cache-status") {
    let modelPath: String?
    let nextIndex = CommandLine.arguments.index(after: cacheStatusIndex)
    if CommandLine.arguments.indices.contains(nextIndex) {
        modelPath = CommandLine.arguments[nextIndex]
    } else {
        modelPath = try? ConfigStore().load().modelPath
    }

    ModelDiagnostics.printParakeetCacheStatus(for: modelPath)
}

// AppKit enters on the process main thread. Make that invariant explicit so
// the app delegate and all UI coordinators remain main-actor isolated under
// complete Swift concurrency checking.
MainActor.assumeIsolated {
    guard SingleInstanceGuard.shared.acquire() else {
        FileHandle.standardError.write(
            Data("YappYapp is already running; ignoring duplicate launch.\n".utf8)
        )
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()

    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
