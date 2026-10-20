import Foundation

// LLM-CLEANUP (YA-10): one cleanup run, start to finish. Never throws and
// never loses a dictation: every failure returns the raw transcript together
// with an honest reason the caller can show.

/// One llama.cpp run, as the runner sees it.
struct CleanupInvocation: Equatable, Sendable {
    var binaryPath: String
    var arguments: [String]
    var input: String
    var timeout: TimeInterval
}

enum CleanupRunResult: Equatable, Sendable {
    case finished(status: Int32, output: String)
    case timedOut
    case launchFailed
}

/// Why the raw transcript went out instead of a cleaned one.
enum CleanupFallback: Equatable, Sendable {
    case runtimeMissing
    case modelMissing
    case timedOut
    case failed
    case rejected(CleanupRejection)

    /// Short HUD caption.
    var hudNote: String {
        switch self {
        case .runtimeMissing: L10n.tr("AS SPOKEN · CAN'T RUN CLEANUP")
        case .modelMissing: L10n.tr("AS SPOKEN · NO CLEANUP MODEL")
        case .timedOut: L10n.tr("AS SPOKEN · CLEANUP TOO SLOW")
        case .failed: L10n.tr("AS SPOKEN · CLEANUP FAILED")
        case .rejected: L10n.tr("AS SPOKEN · CLEANUP CHANGED TOO MUCH")
        }
    }

    /// One plain sentence for the MIC tab.
    var message: String {
        switch self {
        case .runtimeMissing:
            L10n.tr("Kept your words as spoken. This copy of YappYapp can't run cleanup.")
        case .modelMissing:
            L10n.tr("Kept your words as spoken. The cleanup model isn't downloaded. See Setup.")
        case .timedOut:
            L10n.tr("Kept your words as spoken. Cleanup took too long.")
        case .failed:
            L10n.tr("Kept your words as spoken. Cleanup hit an error.")
        case .rejected(let rejection):
            L10n.tr("Kept your words as spoken: %@.", rejection.reason)
        }
    }
}

enum CleanupOutcome: Equatable, Sendable {
    /// The model's rewrite passed every check and replaced the transcript.
    case cleaned
    /// Nothing to do: Verbatim mode, or too short to be worth a model load.
    case skipped
    case fellBack(CleanupFallback)
}

struct CleanupResult: Equatable, Sendable {
    var text: String
    var outcome: CleanupOutcome
}

/// Everything a run touches outside pure logic, so tests can swap it.
struct CleanupEnvironment: Sendable {
    var binaryPath: @Sendable (String) -> String?
    var modelReady: @Sendable () -> Bool
    var modelPath: @Sendable () -> String
    var run: @Sendable (CleanupInvocation) -> CleanupRunResult
    /// LLM-CLEANUP-WARM: the warm llama-server, tried first for the bundled
    /// llama-completion runtime. `.unavailable` falls back to `run`.
    var server: @Sendable (CleanupServerRequest) -> LlamaServerReply = { _ in .unavailable }

    static let live = CleanupEnvironment(
        binaryPath: { LLMCleaner.binaryPath(configured: $0) },
        modelReady: { CleanupModelStore.isVerified() },
        modelPath: { LLMCleaner.modelURL.path },
        run: { LLMCleaner.runProcess($0) },
        server: { LlamaServerController.cleanup.complete($0) }
    )
}

extension LLMCleaner {
    /// Whether a llama.cpp runtime the policy allows exists for this config.
    static func isRuntimeAvailable(configured: String) -> Bool {
        binaryPath(configured: configured) != nil
    }

    /// Cleans `text` in `mode`. Blocking (up to `hardTimeout`): call it off
    /// the main thread. `protectedTerms` are glossary canonicals; the caller
    /// re-applies the glossary afterwards so names always win.
    static func cleanup(
        text: String,
        mode: CleanupMode,
        protectedTerms: [String] = [],
        numbers: NumberPlan = .asSpoken,
        llamaBinaryPath: String = stockBinaryPath,
        environment: CleanupEnvironment = .live
    ) -> CleanupResult {
        guard mode.usesModel, isWorthCleaning(text) else {
            return CleanupResult(text: text, outcome: .skipped)
        }
        guard let binary = environment.binaryPath(llamaBinaryPath) else {
            return CleanupResult(text: text, outcome: .fellBack(.runtimeMissing))
        }
        guard environment.modelReady() else {
            return CleanupResult(text: text, outcome: .fellBack(.modelMissing))
        }

        // Spoken corrections are applied by rule first (PROMPT-TUNING LOG:
        // the model resolves them to the wrong side).
        let corrected = SelfCorrection.resolve(text)
        let runtime = Runtime.of(binaryPath: binary)
        let invocation = CleanupInvocation(
            binaryPath: binary,
            arguments: processArguments(
                tokenBudget: tokenBudget(for: corrected),
                mode: mode,
                runtime: runtime,
                modelPath: environment.modelPath(),
                numbers: numbers.promptStyle
            ),
            input: inputPayload(transcript: corrected, protectedTerms: protectedTerms),
            timeout: hardTimeout(for: corrected)
        )

        // LLM-CLEANUP-WARM: the warm server answers in a fraction of the
        // one-shot time. Same rules, same payload, same acceptance checks.
        // A llama-cli the user chose never has a server.
        if runtime == .completion {
            let reply = environment.server(CleanupServerRequest(
                system: systemPrompt(mode: mode, protectedTerms: [], numbers: numbers.promptStyle),
                user: invocation.input,
                maxTokens: tokenBudget(for: corrected),
                timeout: invocation.timeout
            ))
            switch reply {
            case .text(let output):
                return accepted(output, runtime: runtime, mode: mode, corrected: corrected, original: text, protectedTerms: protectedTerms, numbers: numbers)
            case .timedOut:
                return CleanupResult(text: text, outcome: .fellBack(.timedOut))
            case .unavailable:
                break
            }
        }

        switch environment.run(invocation) {
        case .timedOut:
            return CleanupResult(text: text, outcome: .fellBack(.timedOut))
        case .launchFailed:
            return CleanupResult(text: text, outcome: .fellBack(.failed))
        case .finished(let status, let output):
            guard status == 0 else {
                return CleanupResult(text: text, outcome: .fellBack(.failed))
            }
            return accepted(output, runtime: runtime, mode: mode, corrected: corrected, original: text, protectedTerms: protectedTerms, numbers: numbers)
        }
    }

    /// The model's reply, tidied and checked. Falls back to `original`.
    private static func accepted(
        _ output: String,
        runtime: Runtime,
        mode: CleanupMode,
        corrected: String,
        original: String,
        protectedTerms: [String],
        numbers: NumberPlan
    ) -> CleanupResult {
        let reply = finish(extractResponse(fromOutput: output, runtime: runtime), mode: mode)
        if let rejection = CleanupAcceptance.evaluate(
            original: corrected, cleaned: reply, mode: mode, protectedTerms: protectedTerms,
            numberLanguage: numbers.isActive ? numbers.language : nil
        ) {
            return CleanupResult(text: original, outcome: .fellBack(.rejected(rejection)))
        }
        // WORDS-NEAR-MISS: the user's words keep the case they went in with.
        return CleanupResult(text: GlossaryNearMiss.restoringCase(of: protectedTerms, from: corrected, in: reply), outcome: .cleaned)
    }

    /// Clean mode, text only. Kept for the --llm-cleanup-smoke harness.
    static func cleanup(transcript: String, protectedTerms: [String] = [], llamaBinaryPath configured: String) -> String {
        cleanup(text: transcript, mode: .clean, protectedTerms: protectedTerms, llamaBinaryPath: configured).text
    }

    /// Runs llama.cpp with the transcript on stdin. The watchdog terminates
    /// it at the deadline and kills it a second later if it is still alive,
    /// so the raw transcript always goes out on time.
    static func runProcess(_ invocation: CleanupInvocation) -> CleanupRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.binaryPath)
        process.arguments = invocation.arguments

        // PIPE-DEADLOCK: drain stdout/stderr concurrently via readabilityHandler
        // (same fix as WhisperTranscriber); llama.cpp logs pages to stderr.
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let collected = LockedData()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData  // drain and discard
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            return .launchFailed
        }

        let timedOut = LockedFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + invocation.timeout, execute: watchdog)

        // A helper that dies before reading its input must not take the app
        // down with SIGPIPE: the write fails quietly and the run falls back.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(invocation.input.utf8))
        try? stdin.fileHandleForWriting.close()

        process.waitUntilExit()
        watchdog.cancel()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collected.append(stdout.fileHandleForReading.readDataToEndOfFile())

        if timedOut.isSet { return .timedOut }
        return .finished(
            status: process.terminationStatus,
            output: String(decoding: collected.data, as: UTF8.self)
        )
    }
}

/// Thread-safe one-way flag for the watchdog.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
